import Foundation
import CoreMedia
import CoreVideo
import AudioToolbox
import Libavformat
import Libavcodec
import Libavfilter
import Libavutil
import Libswresample

/// Mirakurun の MPEG-2 TS を受信 → デマックス → デコードし、CMSampleBuffer を吐き出す。
/// 専用スレッド 1 本で動く（MPEG-2 デコード自体は libavcodec のフレームスレッドで並列化）。
///
/// Step 2 以降の拡張ポイント:
///   - 字幕: AVMEDIA_TYPE_SUBTITLE (codec_id ARIB_CAPTION) のパケットを libaribcaption へ
///   - データ放送: DSM-CC の PID を別途拾って web-bml へ
final class TSPipeline {

    struct StreamInfo {
        var videoCodec = "-"
        var audioCodec = "-"
        var width = 0
        var height = 0
        /// 表示アスペクト比 (地デジ 1440x1080 SAR 4:3 → 16:9)
        var displayAspect: Double = 16.0 / 9.0
        var audioChannels = 0
        var hasAudio = false
        /// ARIB 字幕のストリームが含まれている（FFmpeg は PID の記述子から arib_caption と認識する）
        var hasCaption = false
        /// 録画ファイル（HTTP Range が使える）のとき: 開始時刻（PTS 秒）・長さ（秒、不明は 0）・シークできるか
        var startTime: Double = 0
        var duration: Double = 0
        var isSeekable = false
    }

    struct Callbacks {
        var video: (CMSampleBuffer) -> Void
        var audio: (CMSampleBuffer) -> Void
        var info: (StreamInfo) -> Void
        /// 字幕パケット（PES のペイロード = data_identifier 0x80 から始まるデータ）と PTS（秒）
        var caption: (Data, Double) -> Void
        /// シークが完了した（読み込み位置が移った）。デコーダー・描画側のバッファを捨てて、時計を取り直す合図
        var seeked: (Double) -> Void
        /// ファイルの終端まで読み終えた（以降はシーク要求を待つ）
        var eof: () -> Void
        var finished: (Error?) -> Void
    }

    private let url: URL
    private let callbacks: Callbacks

    /// 録画ファイルの再生か（true のとき、終端で止まって待ち、シークを受け付ける）
    var isFileMode = false
    /// 音声のみ: 映像のパケットを読み捨てて、デコードしない（CPU・電池の節約）
    var audioOnly = false
    private var fileSize: Int64 = 0
    private let seekLock = NSLock()
    private var _pendingSeek: Double?
    /// シーク後、目標より前のフレーム（PTS 秒未満）は捨てる。目標の少し手前から読み始めるため
    private var skipBefore: Double?
    private var thread: Thread?

    private let stopLock = NSLock()
    private var _stopRequested = false
    fileprivate var stopRequested: Bool {
        stopLock.lock(); defer { stopLock.unlock() }
        return _stopRequested
    }

    // FFmpeg 状態（パイプラインスレッド専用）
    private var fmt: UnsafeMutablePointer<AVFormatContext>?
    private var videoIndex: Int32 = -1
    private var audioIndex: Int32 = -1
    private var captionIndex: Int32 = -1
    private var captionTimeBase = AVRational(num: 1, den: 90000)
    private var videoDec: UnsafeMutablePointer<AVCodecContext>?
    private var audioDec: UnsafeMutablePointer<AVCodecContext>?
    private var videoTimeBase = AVRational(num: 1, den: 90000)
    private var audioTimeBase = AVRational(num: 1, den: 90000)

    // デインターレース用フィルタグラフ
    private var graph: UnsafeMutablePointer<AVFilterGraph>?
    private var bufSrc: UnsafeMutablePointer<AVFilterContext>?
    private var bufSink: UnsafeMutablePointer<AVFilterContext>?
    private var graphKey = (w: Int32(0), h: Int32(0), fmt: Int32(-1))

    // 音声リサンプラ（5.1ch / ステレオ / デュアルモノ切替に追従）
    private var swr: OpaquePointer?
    private var swrInLayout = AVChannelLayout()
    private var swrInRate: Int32 = 0
    private var swrInFormat: Int32 = -1
    private static let outRate: Int32 = 48_000
    private static let outChannels: Int32 = 2
    private var audioFormatDesc: CMAudioFormatDescription?
    private var nextAudioPTS: Double?

    // 映像出力
    private var pixelPool: CVPixelBufferPool?
    private var poolSize = (w: 0, h: 0)
    private var videoFormatDesc: CMVideoFormatDescription?

    private var info = StreamInfo()

    /// デュアルモノ（主/副音声）の選択。ISDB のデュアルモノは L=主・R=副の 2ch で来る
    enum AudioMode { case both, main, sub }
    private let audioModeLock = NSLock()
    private var _audioMode: AudioMode = .both
    var audioMode: AudioMode {
        get { audioModeLock.lock(); defer { audioModeLock.unlock() }; return _audioMode }
        set { audioModeLock.lock(); _audioMode = newValue; audioModeLock.unlock() }
    }
    private var appliedAudioMode: AudioMode = .both

    init(url: URL, callbacks: Callbacks) {
        self.url = url
        self.callbacks = callbacks
    }

    func start() {
        let t = Thread { [self] in
            var err: Error?
            do { try run() } catch { err = error }
            cleanup()
            callbacks.finished(stopRequested ? nil : err)
        }
        t.name = "MiraTV.TSPipeline"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// 録画のシーク要求（PTS 秒）。実際の移動はパイプラインスレッドが次のループで行う
    func requestSeek(_ seconds: Double) {
        seekLock.lock(); _pendingSeek = seconds; seekLock.unlock()
    }

    private func takePendingSeek() -> Double? {
        seekLock.lock(); defer { seekLock.unlock() }
        let t = _pendingSeek
        _pendingSeek = nil
        return t
    }

    private var hasPendingSeek: Bool {
        seekLock.lock(); defer { seekLock.unlock() }
        return _pendingSeek != nil
    }

    /// av_read_frame のブロックは interrupt callback で抜ける
    func stop() {
        stopLock.lock(); _stopRequested = true; stopLock.unlock()
    }

    // MARK: - Main loop

    /// 受信を別スレッドで先読みする（FFmpeg の async: プロトコル、4MB ≒ 地デジ 2 秒ぶん）。
    /// デコードと受信を切り離して、回線の揺れで映像・音声が途切れにくくする。使えないビルドなら通常の http で開き直す
    static var useReadAhead = true
    /// このビルドの FFmpeg に async: プロトコルが入っているか（1 回だけ調べる）
    private static let hasAsyncProtocol: Bool = {
        let ok = avio_find_protocol_name("async:http://example.invalid/") != nil
        DebugLog.log("player", "先読み(async:) \(ok ? "使用" : "このビルドに無いため不使用")")
        return ok
    }()

    /// avformat_open_input は失敗すると渡した AVFormatContext を解放するので、開き直すたびに作り直す
    private func openInput(_ urlString: String) -> Int32 {
        guard let ctx = avformat_alloc_context() else { return -12 }   // ENOMEM
        ctx.pointee.interrupt_callback.callback = { opaque in
            guard let opaque else { return 0 }
            return Unmanaged<TSPipeline>.fromOpaque(opaque).takeUnretainedValue().stopRequested ? 1 : 0
        }
        ctx.pointee.interrupt_callback.opaque = Unmanaged.passUnretained(self).toOpaque()
        self.fmt = ctx

        var opts: OpaquePointer?
        av_dict_set(&opts, "probesize", "2000000", 0)
        av_dict_set(&opts, "analyzeduration", "2000000", 0)   // µs
        av_dict_set(&opts, "rw_timeout", "15000000", 0)        // µs, http
        av_dict_set(&opts, "user_agent", "MiraTV/0.1", 0)
        av_dict_set(&opts, "headers", "X-Mirakurun-Priority: 0\r\n", 0)
        let r = avformat_open_input(&self.fmt, urlString, nil, &opts)
        av_dict_free(&opts)
        return r
    }

    private func run() throws {
        let plain = url.absoluteString
        var r: Int32
        // 開けなかったときに http で開き直すと、サーバーが落ちているだけでも待ち時間が 2 倍になるので、
        // async: が使えるかは事前に 1 回だけ判定し、開き直しはしない
        if Self.useReadAhead && Self.hasAsyncProtocol && (url.scheme == "http" || url.scheme == "https") {
            r = openInput("async:" + plain)
        } else {
            r = openInput(plain)
        }
        guard r >= 0, let fmt = self.fmt else { throw PipelineError("ストリームを開けません", r) }

        r = avformat_find_stream_info(fmt, nil)
        guard r >= 0 else { throw PipelineError("ストリーム解析に失敗", r) }

        videoIndex = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        audioIndex = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, videoIndex, nil, 0)
        // 音声のみ（streamd が映像を抜いた TS）は映像が無くてよい
        guard videoIndex >= 0 || (audioOnly && audioIndex >= 0) else { throw PipelineError("映像ストリームが見つかりません") }
        // 字幕は第 1 言語のみ（映像と同じ番組のもの）。無ければ負の値が返る
        captionIndex = av_find_best_stream(fmt, AVMEDIA_TYPE_SUBTITLE, -1, videoIndex, nil, 0)

        if videoIndex >= 0 {
            let vst = fmt.pointee.streams[Int(videoIndex)]!
            videoDec = try openDecoder(vst, video: true)
            videoTimeBase = vst.pointee.time_base
            info.videoCodec = String(cString: avcodec_get_name(vst.pointee.codecpar.pointee.codec_id))
        }

        if audioIndex >= 0 {
            let ast = fmt.pointee.streams[Int(audioIndex)]!
            audioDec = try openDecoder(ast, video: false)
            audioTimeBase = ast.pointee.time_base
            info.audioCodec = String(cString: avcodec_get_name(ast.pointee.codecpar.pointee.codec_id))
            info.hasAudio = true
        }
        // 使わないストリームは読み飛ばす（Step 2/3 で字幕・データを有効化する）
        if captionIndex >= 0 {
            captionTimeBase = fmt.pointee.streams[Int(captionIndex)]!.pointee.time_base
            info.hasCaption = true
        }
        for i in 0..<Int(fmt.pointee.nb_streams) where Int32(i) != videoIndex && Int32(i) != audioIndex && Int32(i) != captionIndex {
            fmt.pointee.streams[i]!.pointee.discard = AVDISCARD_ALL
        }
        if audioOnly && audioIndex >= 0 && videoIndex >= 0 {
            fmt.pointee.streams[Int(videoIndex)]!.pointee.discard = AVDISCARD_ALL
        }
        // 録画ファイル: 開始時刻・長さ・シーク可否（TvtPlay の「先頭 PCR と末尾 PCR の差」に相当。
        // libavformat がシーク可能な HTTP の末尾から PTS を読んで見積もる）
        if isFileMode {
            let st = fmt.pointee.start_time
            info.startTime = st != kAVNoPTS ? Double(st) / 1_000_000 : 0
            let d = fmt.pointee.duration
            info.duration = (d != kAVNoPTS && d > 0) ? Double(d) / 1_000_000 : 0
            if let pb = fmt.pointee.pb {
                fileSize = avio_size(pb)
                info.isSeekable = pb.pointee.seekable != 0 && fileSize > 0
            }
        }
        callbacks.info(info)

        let pkt = av_packet_alloc()
        let frame = av_frame_alloc()
        var pktOpt = pkt, frameOpt = frame
        defer { av_packet_free(&pktOpt); av_frame_free(&frameOpt) }
        guard let pkt, let frame else { throw PipelineError("alloc failed") }

        while !stopRequested {
            if let target = takePendingSeek() {
                performSeek(to: target, pkt: pkt)
                continue
            }
            r = av_read_frame(fmt, pkt)
            if r == kAVErrorEAGAIN { continue }
            if r < 0 {
                if stopRequested { break }
                if isFileMode && info.isSeekable && r == kAVErrorEOF {
                    // 終端まで読み終えた。再生はまだ続いているので、スレッドは生かしてシーク要求（もう一度再生など）を待つ
                    callbacks.eof()
                    while !stopRequested && !hasPendingSeek { Thread.sleep(forTimeInterval: 0.05) }
                    continue
                }
                throw PipelineError(r == kAVErrorEOF ? "ストリームが終了しました" : "受信エラー", r)
            }
            if pkt.pointee.stream_index == videoIndex, let dec = videoDec {
                decode(dec, pkt, frame) { self.handleVideoFrame($0) }
            } else if pkt.pointee.stream_index == audioIndex, let dec = audioDec {
                decode(dec, pkt, frame) { self.handleAudioFrame($0) }
            } else if pkt.pointee.stream_index == captionIndex, captionIndex >= 0,
                      pkt.pointee.size > 0, let bytes = pkt.pointee.data {
                let ts = pkt.pointee.pts != kAVNoPTS ? pkt.pointee.pts : pkt.pointee.dts
                if ts != kAVNoPTS {
                    callbacks.caption(Data(bytes: bytes, count: Int(pkt.pointee.size)), Double(ts) * captionTimeBase.double)
                }
            }
            av_packet_unref(pkt)
        }
    }

    private func openDecoder(_ st: UnsafeMutablePointer<AVStream>, video: Bool) throws -> UnsafeMutablePointer<AVCodecContext> {
        let par = st.pointee.codecpar!
        guard let codec = avcodec_find_decoder(par.pointee.codec_id) else {
            throw PipelineError("デコーダがありません: \(String(cString: avcodec_get_name(par.pointee.codec_id)))")
        }
        guard let ctx = avcodec_alloc_context3(codec) else { throw PipelineError("avcodec_alloc_context3 failed") }
        avcodec_parameters_to_context(ctx, par)
        ctx.pointee.pkt_timebase = st.pointee.time_base
        if video {
            ctx.pointee.thread_count = 0                       // 自動（コア数）
            ctx.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
        }
        let r = avcodec_open2(ctx, codec, nil)
        guard r >= 0 else { throw PipelineError("デコーダを開けません", r) }
        return ctx
    }

    private func decode(_ ctx: UnsafeMutablePointer<AVCodecContext>,
                        _ pkt: UnsafeMutablePointer<AVPacket>,
                        _ frame: UnsafeMutablePointer<AVFrame>,
                        _ handler: (UnsafeMutablePointer<AVFrame>) -> Void) {
        // 途中から受信した TS の先頭は壊れたパケットが来るのでエラーは握りつぶす
        guard avcodec_send_packet(ctx, pkt) >= 0 else { return }
        while avcodec_receive_frame(ctx, frame) >= 0 {
            handler(frame)
            av_frame_unref(frame)
        }
    }

    // MARK: - Seek（録画ファイル）
    //
    // TvtPlay (xtne6f/TvtPlay, TsSender.cpp) と同じ考え方: 長さとレートからバイト位置を概算して飛び、
    // 着いた先の実際の時刻を測って、レートを補正しながら数回で収束させる（docs/tvtplay-analysis.md 参照）。
    // TvtPlay は PCR で測るが、ここでは次に読めた映像/音声パケットの PTS で測る。

    /// 録画のシーク。目標（PTS 秒）の 0〜約 4 秒手前に着地し、そこからデコードして目標より前のフレームを捨てる
    private func performSeek(to requested: Double, pkt: UnsafeMutablePointer<AVPacket>) {
        guard fmt != nil, info.isSeekable, fileSize > 0 else { callbacks.seeked(requested); return }
        let start = info.startTime
        let dur = max(info.duration, 1)
        // 末尾の約 2 秒手前まで（TvtPlay の SeekToEnd と同じ）
        let target = min(max(requested, start), start + max(dur - 2, 0))
        let unit: Int64 = 188
        let maxByte = max(fileSize - unit * 200, 0)
        var rate = max(Double(fileSize) / dur, 100_000)          // bytes/s（TvtPlay の GetRate 相当）
        var pos = Int64(Double(fileSize) * (target - start) / dur)
        var samples: [(pos: Int64, time: Double)] = []
        var landed: Double?

        for _ in 0..<7 {
            if stopRequested { return }
            pos = min(max(pos, 0), maxByte)
            pos -= pos % unit
            guard let t = probe(at: pos, pkt: pkt) else { break }
            samples.append((pos, t))
            let diff = target - t                                // 正 = まだ前方へ進む必要がある
            if diff >= -0.3 && diff <= 4.0 { landed = t; break }  // 目標の 0〜4 秒手前（または僅かな行き過ぎ）
            if samples.count >= 2 {
                // 直近 2 点から、この辺りの実測レートを出し直す（極端な値は抑える）
                let a = samples[samples.count - 2], b = samples[samples.count - 1]
                if abs(b.time - a.time) > 0.2 {
                    let local = abs(Double(b.pos - a.pos) / (b.time - a.time))
                    rate = min(max(local, Double(fileSize) / dur / 4), Double(fileSize) / dur * 4)
                }
            }
            // 目標の 1.5 秒手前を狙って動く（行き過ぎると戻る回数が増えるため）
            pos += Int64(rate * (diff - 1.5))
        }

        // 収束しなかったときは、測れた中で目標に最も近い手前の点を使う。何も測れなければ先頭から
        if landed == nil {
            if let best = samples.filter({ $0.time <= target }).max(by: { $0.time < $1.time }) {
                if let t = probe(at: best.pos, pkt: pkt) { landed = t }
            }
        }
        if landed == nil { landed = probe(at: 0, pkt: pkt) }

        // デコーダー・フィルタ・リサンプラの内部状態を捨てる（古いフレームが混ざらないように）
        if let v = videoDec { avcodec_flush_buffers(v) }
        if let a = audioDec { avcodec_flush_buffers(a) }
        avfilter_graph_free(&graph)
        graph = nil; bufSrc = nil; bufSink = nil
        graphKey = (w: 0, h: 0, fmt: -1)
        swr_free(&swr)
        nextAudioPTS = nil
        skipBefore = target
        callbacks.seeked(target)
    }

    /// バイト位置へ飛んで、最初に PTS が付いた映像/音声パケットの時刻（PTS 秒）を返す
    private func probe(at pos: Int64, pkt: UnsafeMutablePointer<AVPacket>) -> Double? {
        guard let fmt else { return nil }
        if av_seek_frame(fmt, -1, pos, AVSEEK_FLAG_BYTE) < 0 { return nil }
        for _ in 0..<6000 {
            if stopRequested { return nil }
            if av_read_frame(fmt, pkt) < 0 { return nil }
            defer { av_packet_unref(pkt) }
            let idx = pkt.pointee.stream_index
            guard idx == videoIndex || idx == audioIndex else { continue }
            let ts = pkt.pointee.pts != kAVNoPTS ? pkt.pointee.pts : pkt.pointee.dts
            if ts == kAVNoPTS { continue }
            return Double(ts) * (idx == videoIndex ? videoTimeBase : audioTimeBase).double
        }
        return nil
    }

    // MARK: - Video

    private func handleVideoFrame(_ f: UnsafeMutablePointer<AVFrame>) {
        let w = f.pointee.width, h = f.pointee.height, pf = f.pointee.format
        if graph == nil || graphKey != (w, h, pf) {
            do { try rebuildFilterGraph(for: f) } catch { return }
            var sar = f.pointee.sample_aspect_ratio
            if sar.num <= 0 || sar.den <= 0 { sar = AVRational(num: 1, den: 1) }
            info.width = Int(w); info.height = Int(h)
            info.displayAspect = Double(w) * sar.double / Double(h)
            callbacks.info(info)
        }
        guard av_buffersrc_add_frame(bufSrc, f) >= 0 else { return }   // f の参照は移譲される

        let out = av_frame_alloc()
        var outOpt = out
        defer { av_frame_free(&outOpt) }
        guard let out else { return }
        let tb = av_buffersink_get_time_base(bufSink)
        while av_buffersink_get_frame(bufSink, out) >= 0 {
            if out.pointee.pts != kAVNoPTS {
                let pts = Double(out.pointee.pts) * tb.double
                if let s = skipBefore, pts < s - 0.001 { av_frame_unref(out); continue }
                if let sb = makeVideoSampleBuffer(out, pts: pts) { callbacks.video(sb) }
            }
            av_frame_unref(out)
        }
    }

    /// buffer → bwdif(インターレースのみ解除) → format=nv12 → buffersink
    private func rebuildFilterGraph(for f: UnsafeMutablePointer<AVFrame>) throws {
        avfilter_graph_free(&graph)
        bufSrc = nil; bufSink = nil
        guard let g = avfilter_graph_alloc() else { throw PipelineError("avfilter_graph_alloc failed") }
        graph = g

        var sar = f.pointee.sample_aspect_ratio
        if sar.num <= 0 || sar.den <= 0 { sar = AVRational(num: 1, den: 1) }
        let args = "video_size=\(f.pointee.width)x\(f.pointee.height):pix_fmt=\(f.pointee.format)"
            + ":time_base=\(videoTimeBase.num)/\(videoTimeBase.den)"
            + ":pixel_aspect=\(sar.num)/\(sar.den)"

        var r = avfilter_graph_create_filter(&bufSrc, avfilter_get_by_name("buffer"), "in", args, nil, g)
        guard r >= 0 else { throw PipelineError("buffer filter", r) }
        r = avfilter_graph_create_filter(&bufSink, avfilter_get_by_name("buffersink"), "out", nil, nil, g)
        guard r >= 0 else { throw PipelineError("buffersink filter", r) }

        var outputs = avfilter_inout_alloc()
        var inputs = avfilter_inout_alloc()
        defer { avfilter_inout_free(&outputs); avfilter_inout_free(&inputs) }
        outputs!.pointee.name = av_strdup("in")
        outputs!.pointee.filter_ctx = bufSrc
        outputs!.pointee.pad_idx = 0
        outputs!.pointee.next = nil
        inputs!.pointee.name = av_strdup("out")
        inputs!.pointee.filter_ctx = bufSink
        inputs!.pointee.pad_idx = 0
        inputs!.pointee.next = nil

        // send_frame: 60i → 30p。滑らかさ重視なら send_field (60p) に変える（CPU 2 倍）
        let desc = "bwdif=mode=send_frame:parity=auto:deint=interlaced,format=nv12"
        r = avfilter_graph_parse_ptr(g, desc, &inputs, &outputs, nil)
        guard r >= 0 else { throw PipelineError("filter parse", r) }
        r = avfilter_graph_config(g, nil)
        guard r >= 0 else { throw PipelineError("filter config", r) }
        graphKey = (f.pointee.width, f.pointee.height, f.pointee.format)
    }

    private func makeVideoSampleBuffer(_ f: UnsafeMutablePointer<AVFrame>, pts: Double) -> CMSampleBuffer? {
        let w = Int(f.pointee.width), h = Int(f.pointee.height)
        if pixelPool == nil || poolSize != (w, h) {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: w,
                kCVPixelBufferHeightKey: h,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            pixelPool = nil
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pixelPool)
            poolSize = (w, h)
            videoFormatDesc = nil
        }
        guard let pool = pixelPool else { return nil }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        copyPlane(src: f.pointee.data.0, srcStride: Int(f.pointee.linesize.0), pb: pb, plane: 0, rows: h, bytes: w)
        copyPlane(src: f.pointee.data.1, srcStride: Int(f.pointee.linesize.1), pb: pb, plane: 1, rows: (h + 1) / 2, bytes: (w + 1) & ~1)
        CVPixelBufferUnlockBaseAddress(pb, [])

        // 画素の縦横比（1440x1080 の 16:9 など）。PiP は表示サイズをバッファの属性から決めるので、付けないと比率が崩れる
        var par = f.pointee.sample_aspect_ratio
        if par.num <= 0 || par.den <= 0 { par = AVRational(num: 1, den: 1) }
        CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey,
                              [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(par.num),
                               kCVImageBufferPixelAspectRatioVerticalSpacingKey: Int(par.den)] as CFDictionary, .shouldPropagate)

        // 地デジ/BS の HD は BT.709、SD は BT.601
        let hd = h > 576
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey,
                              hd ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                              hd ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)

        if videoFormatDesc == nil || !CMVideoFormatDescriptionMatchesImageBuffer(videoFormatDesc!, imageBuffer: pb) {
            videoFormatDesc = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &videoFormatDesc)
        }
        guard let fd = videoFormatDesc else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90_000),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fd,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        return sb
    }

    private func copyPlane(src: UnsafeMutablePointer<UInt8>?, srcStride: Int, pb: CVPixelBuffer,
                           plane: Int, rows: Int, bytes: Int) {
        guard let src, let dst = CVPixelBufferGetBaseAddressOfPlane(pb, plane) else { return }
        let dstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
        let rowsToCopy = min(rows, CVPixelBufferGetHeightOfPlane(pb, plane))
        let n = min(bytes, dstStride, srcStride)
        if srcStride == dstStride {
            memcpy(dst, src, dstStride * rowsToCopy)
        } else {
            for y in 0..<rowsToCopy {
                memcpy(dst + y * dstStride, src + y * srcStride, n)
            }
        }
    }

    // MARK: - Audio

    private func handleAudioFrame(_ f: UnsafeMutablePointer<AVFrame>) {
        if swr == nil
            || av_channel_layout_compare(&swrInLayout, &f.pointee.ch_layout) != 0
            || swrInRate != f.pointee.sample_rate
            || swrInFormat != f.pointee.format
            || appliedAudioMode != audioMode {
            guard rebuildResampler(for: f) else { return }
        }

        // PTS（無ければ前フレームから補間）
        let ts = f.pointee.best_effort_timestamp != kAVNoPTS ? f.pointee.best_effort_timestamp : f.pointee.pts
        let pts: Double
        if ts != kAVNoPTS {
            pts = Double(ts) * audioTimeBase.double
        } else if let next = nextAudioPTS {
            pts = next
        } else { return }

        if let s = skipBefore, pts < s - 0.001 {
            nextAudioPTS = pts + Double(f.pointee.nb_samples) / Double(max(f.pointee.sample_rate, 1))
            return
        }

        let out = av_frame_alloc()
        var outOpt = out
        defer { av_frame_free(&outOpt) }
        guard let out else { return }
        av_channel_layout_default(&out.pointee.ch_layout, Self.outChannels)
        out.pointee.sample_rate = Self.outRate
        out.pointee.format = AV_SAMPLE_FMT_FLT.rawValue
        guard swr_convert_frame(swr, out, f) >= 0, out.pointee.nb_samples > 0, let data = out.pointee.data.0 else { return }

        let samples = Int(out.pointee.nb_samples)
        nextAudioPTS = pts + Double(samples) / Double(Self.outRate)
        if let sb = makeAudioSampleBuffer(data, samples: samples, pts: pts) { callbacks.audio(sb) }
    }

    private func rebuildResampler(for f: UnsafeMutablePointer<AVFrame>) -> Bool {
        swr_free(&swr)
        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, Self.outChannels)
        defer { av_channel_layout_uninit(&outLayout) }
        var r = swr_alloc_set_opts2(&swr, &outLayout, AV_SAMPLE_FMT_FLT, Self.outRate,
                                    &f.pointee.ch_layout, AVSampleFormat(rawValue: f.pointee.format),
                                    f.pointee.sample_rate, 0, nil)
        guard r >= 0 else { return false }
        // 主/副の選択はミックス行列で表す（出力 L/R それぞれにどの入力 ch を割り当てるか）。
        // swr_set_matrix は swr_init の前に呼ぶ必要がある
        let mode = audioMode
        appliedAudioMode = mode
        if mode != .both, f.pointee.ch_layout.nb_channels == 2 {
            var matrix: [Double] = mode == .main ? [1, 0, 1, 0] : [0, 1, 0, 1]
            _ = swr_set_matrix(swr, &matrix, 2)
        }
        r = swr_init(swr)
        guard r >= 0 else { swr_free(&swr); return false }

        av_channel_layout_uninit(&swrInLayout)
        av_channel_layout_copy(&swrInLayout, &f.pointee.ch_layout)
        swrInRate = f.pointee.sample_rate
        swrInFormat = f.pointee.format
        info.audioChannels = Int(f.pointee.ch_layout.nb_channels)
        callbacks.info(info)

        if audioFormatDesc == nil {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(Self.outRate),
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(4 * Self.outChannels),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(4 * Self.outChannels),
                mChannelsPerFrame: UInt32(Self.outChannels),
                mBitsPerChannel: 32,
                mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &audioFormatDesc)
        }
        return true
    }

    private func makeAudioSampleBuffer(_ data: UnsafeMutablePointer<UInt8>, samples: Int, pts: Double) -> CMSampleBuffer? {
        guard let fd = audioFormatDesc else { return nil }
        let length = samples * 4 * Int(Self.outChannels)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: fd, sampleCount: samples,
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: CMTimeScale(Self.outRate)),
            packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }

    // MARK: - Cleanup

    private func cleanup() {
        avfilter_graph_free(&graph)
        swr_free(&swr)
        av_channel_layout_uninit(&swrInLayout)
        avcodec_free_context(&videoDec)
        avcodec_free_context(&audioDec)
        avformat_close_input(&fmt)
        pixelPool = nil
    }
}
