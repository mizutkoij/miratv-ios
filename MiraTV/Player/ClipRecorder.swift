import AVFoundation
import Photos

/// 再生中の映像と音声を、そのまま動画（H.264 + AAC の mp4）に書き出して写真アプリに保存する。
/// 放送の MPEG-2 は写真アプリが読めないので、端末でデコード済みの 1 枚 1 枚をハードウェアのエンコーダーに渡す。
/// 字幕・実況コメントは入らない（「写真」と同じ）
final class ClipRecorder {
    /// これを超えたら自動で止める（端末の空きと書き出し時間のため）
    static let maxSeconds: Double = 300

    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let channels: Int
    private let url: URL
    private var started = false
    private var firstPTS: CMTime = .invalid
    private var lastPTS: CMTime = .invalid
    private(set) var finished = false
    private var limitFired = false
    /// 長さの上限に達した・書き出しが失敗した（呼び出し側が止めて保存する。1 回だけ呼ぶ）
    var onLimit: (() -> Void)?

    /// width / height: 書き出す大きさ（表示の縦横比に直したもの）
    /// channels: 入ってくる音声のチャンネル数（2 か 6）。録り始めたときの番組に合わせる
    init?(width: Int, height: Int, channels: Int = 2) {
        self.channels = channels == 6 ? 6 : 2
        url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        writer = w
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // 1440x1080（横に縮めて送られている地デジ）なども、表示どおりの 16:9 に引き伸ばして書く
            AVVideoScalingModeKey: AVVideoScalingModeResize,
            // 元の映像に付いている 4:3 の画素比（1440x1080）を引き継がない
            AVVideoPixelAspectRatioKey: [AVVideoPixelAspectRatioHorizontalSpacingKey: 1,
                                         AVVideoPixelAspectRatioVerticalSpacingKey: 1],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        v.expectsMediaDataInRealTime = true
        // 音声: TSPipeline は 48kHz の float PCM（2ch か 5.1ch）で出す（入力は書き始める前に全部足す必要がある）
        // 書き出し側の並びは AAC の 5.1（C L R Ls Rs LFE）。入ってくる L R C LFE Ls Rs からは AVAssetWriter が並べ替える。
        // 6ch の AAC を受け付けない端末なら、ステレオにまとめて書く（作れない設定で作ると例外で落ちるので先に確かめる）
        func audioSettings(_ ch: Int) -> [String: Any] {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = ch == 6 ? kAudioChannelLayoutTag_AAC_5_1 : kAudioChannelLayoutTag_Stereo
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: ch,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
                AVEncoderBitRateKey: ch == 6 ? 384_000 : 192_000,
            ]
        }
        var settings = audioSettings(self.channels)
        if self.channels == 6 && !w.canApply(outputSettings: settings, forMediaType: .audio) { settings = audioSettings(2) }
        guard w.canApply(outputSettings: settings, forMediaType: .audio) else { return nil }
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        a.expectsMediaDataInRealTime = true
        guard writer.canAdd(v), writer.canAdd(a) else { return nil }
        writer.add(v)
        writer.add(a)
        videoInput = v
        audioInput = a
        guard writer.startWriting() else { return nil }
    }

    func appendVideo(_ sb: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        if writer.status == .failed {
            // 背面に回った・PiP などでエンコーダーが使えなくなった → すぐ呼び出し側に知らせる
            fireLimit()
            return
        }
        guard writer.status == .writing else { return }
        let pts = sb.presentationTimeStamp
        if !started {
            writer.startSession(atSourceTime: pts)
            started = true
            firstPTS = pts
        }
        if lastPTS.isValid, pts <= lastPTS { return }          // 戻った時刻（シークの残りなど）は捨てる
        lastPTS = pts
        if videoInput.isReadyForMoreMediaData { videoInput.append(sb) }
        if (pts - firstPTS).seconds >= Self.maxSeconds { fireLimit() }
    }

    /// lock を持った状態で呼ぶ
    private func fireLimit() {
        guard !limitFired else { return }
        limitFired = true
        let cb = onLimit
        DispatchQueue.main.async { cb?() }
    }

    func appendAudio(_ sb: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, started, writer.status == .writing,
              sb.presentationTimeStamp >= firstPTS else { return }
        // 途中で番組が替わってチャンネル数が変わった分は書かない（形式を変えられないため）
        if let fd = CMSampleBufferGetFormatDescription(sb),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
           Int(asbd.mChannelsPerFrame) != channels { return }
        if audioInput.isReadyForMoreMediaData { audioInput.append(sb) }
    }

    /// 秒（ボタンの表示用）
    var seconds: Double {
        lock.lock(); defer { lock.unlock() }
        guard firstPTS.isValid, lastPTS.isValid else { return 0 }
        return max((lastPTS - firstPTS).seconds, 0)
    }

    /// 止めて mp4 を書き終え、写真アプリに保存する。結果の一言を返す
    func finishAndSave() async -> String {
        lock.lock()
        guard !finished else { lock.unlock(); return "" }
        finished = true
        let hadFrames = started
        lock.unlock()
        guard hadFrames else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return "まだ映像がありません"
        }
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        await writer.finishWriting()
        defer { try? FileManager.default.removeItem(at: url) }
        guard writer.status == .completed else {
            return "動画を書き出せませんでした: \(writer.error?.localizedDescription ?? "")"
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return "写真への保存が許可されていません（設定 › プライバシー › 写真）"
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: self.url)
            }
            return "動画を写真に保存しました"
        } catch {
            return "保存できませんでした: \(error.localizedDescription)"
        }
    }

    /// 保存せずに捨てる（選局・シーク・閉じたとき）
    func cancel() {
        lock.lock()
        let was = finished
        finished = true
        lock.unlock()
        guard !was else { return }
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}
