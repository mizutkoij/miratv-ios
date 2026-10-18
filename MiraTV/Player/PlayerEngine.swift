import Foundation
import AVFoundation
import Combine
import UIKit

/// TSPipeline が吐く CMSampleBuffer を AVSampleBuffer 系レンダラに流し、
/// AVSampleBufferRenderSynchronizer で音声基準の A/V 同期をとる。
final class PlayerEngine: ObservableObject {

    enum State: Equatable {
        case idle, connecting, buffering, playing
        case failed(String)
    }

    @Published private(set) var state: State = .idle {
        didSet { if oldValue != state { DebugLog.log("player", "state \(oldValue) -> \(state) pos=\(String(format: "%.1f", position))") } }
    }
    @Published private(set) var info = TSPipeline.StreamInfo()

    // MARK: 録画ファイルの再生（位置・長さ・一時停止・速度・シーク）。ライブでは使わない
    /// 再生位置（秒、先頭 = 0）。時計（synchronizer）の PTS から先頭の PTS を引いて求める
    @Published private(set) var position: Double = 0
    /// 長さ（秒）。libavformat の見積もり、無ければ呼び出し側が渡した値（EPGStation の放送時間）
    @Published private(set) var duration: Double = 0
    @Published private(set) var isSeekable = false
    @Published private(set) var isPaused = false
    @Published private(set) var playbackRate: Double = 1
    /// 終端まで再生した
    @Published private(set) var reachedEnd = false
    var durationHint: Double?
    private var isFile = false
    private var startTime: Double = 0
    private var seekTarget: Double?
    private var positionTimer: Timer?
    private var pausedFlag = false          // clockLock で保護（パイプラインスレッドからも読む）
    private var speedValue: Double = 1.0    // clockLock で保護
    private var seekPendingFlag = false     // clockLock で保護
    /// 入れ済みの映像・音声それぞれの末尾の PTS（秒）。clockLock で保護。
    /// 時計が「遅い方」に追いついたら「データ切れ」。以前は両者の大きい方で見ていたため、
    /// 帯域が足りず音声だけ先に尽きても時計が進み続け、遅れて届いた音声が「過去」として捨てられて無音になっていた
    private var audioEnd: Double = 0
    private var videoEnd: Double = 0
    /// 音声が 3 秒以上届いていない（音声の切替・デコード失敗など）ときは、映像だけで判定する。
    /// でないと音声が戻るまで時計が止まったままになる
    private var mediaEnd: Double {
        if audioOnlyMode && expectAudio { return audioEnd }
        guard expectAudio, audioEnd > 0, videoEnd - audioEnd <= 3 else { return videoEnd }
        return min(audioEnd, videoEnd)
    }
    /// データ切れで時計を止めている間 true（clockLock で保護）。止めないと、遅れて届いた音声が
    /// すべて「過去の時刻」扱いで捨てられ、無音のまま追いつけなくなる
    private var stalled = false

    /// 主/副音声の選択（デュアルモノの番組だけ意味がある）。選局のたびに「両方」へ戻す
    @Published var audioMode: TSPipeline.AudioMode = .both {
        didSet { pipeline?.audioMode = audioMode }
    }

    let displayLayer = AVSampleBufferDisplayLayer()
    /// ピクチャ・イン・ピクチャ（ライブ映像用）
    lazy var pip = PiPController(layer: displayLayer)
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var videoRenderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

    private var pipeline: TSPipeline?

    // MARK: 字幕
    /// 映像の時計（synchronizer）が PTS に届いた字幕パケットを、まとめて受け取る（メインスレッド）。描画は呼び出し側（WebView）
    var captionHandler: (([Data]) -> Void)?
    private var captionQueue: [(pts: Double, data: Data)] = []
    private let captionLock = NSLock()
    private var captionTimer: Timer?
    /// 選局のたびに増やす。stop() 済みの旧パイプラインが遅れて吐くフレーム/コールバックを捨てるため
    private let genLock = NSLock()
    private var generation = 0
    private func isCurrent(_ g: Int) -> Bool { genLock.lock(); defer { genLock.unlock() }; return g == generation }

    // クロック開始判定（パイプラインスレッドから触る）
    private let clockLock = NSLock()
    private var clockStarted = false
    private var firstAudioPTS: CMTime?
    private var sawVideo = false
    private var expectAudio = true
    /// 再生開始前に貯める秒数。小さくすると低遅延だが途切れやすい
    var startupBuffer: Double = 0.8
    /// 次の play() を音声のみで行う（映像をデコードしない）
    var audioOnly = false
    /// いまの再生が音声のみか（clockLock で保護）
    private var audioOnlyMode = false

    init() {
        displayLayer.videoGravity = .resize   // アスペクトは SwiftUI 側で DAR に合わせる
        displayLayer.backgroundColor = UIColor.black.cgColor
        synchronizer.addRenderer(audioRenderer)
        synchronizer.addRenderer(videoRenderer)
    }

    func play(url: URL, file: Bool = false) {
        stop()
        isFile = file
        position = 0; duration = 0; isSeekable = false; isPaused = false; reachedEnd = false
        seekTarget = nil
        genLock.lock(); generation += 1; let gen = generation; genLock.unlock()
        try? AVAudioSession.sharedInstance().setActive(true)
        clockLock.lock()
        clockStarted = false; firstAudioPTS = nil; sawVideo = false; expectAudio = true; audioOnlyMode = audioOnly
        pausedFlag = false; seekPendingFlag = false; audioEnd = 0; videoEnd = 0; stalled = false
        clockLock.unlock()
        state = .connecting
        positionTimer?.invalidate(); positionTimer = nil
        if file {
            positionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.pumpPosition() }
        }
        captionLock.lock(); captionQueue.removeAll(); captionLock.unlock()
        captionTimer?.invalidate()
        captionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.pumpCaptions(); self?.checkStall() }

        let callbacks = TSPipeline.Callbacks(
            video: { [weak self] sb in if let self, self.isCurrent(gen) { self.throttle(sb.presentationTimeStamp, gen: gen); self.enqueueVideo(sb) } },
            audio: { [weak self] sb in if let self, self.isCurrent(gen) { self.throttle(sb.presentationTimeStamp, gen: gen); self.enqueueAudio(sb) } },
            info: { [weak self] info in
                guard let self, self.isCurrent(gen) else { return }
                DispatchQueue.main.async {
                    self.info = info
                    self.startTime = info.startTime
                    self.isSeekable = info.isSeekable
                    self.duration = info.duration > 0 ? info.duration : (self.durationHint ?? 0)
                    if self.state == .connecting { self.state = .buffering }
                }
                self.setExpectAudio(info.hasAudio)
            },
            caption: { [weak self] data, pts in
                guard let self, self.isCurrent(gen) else { return }
                self.captionLock.lock()
                self.captionQueue.append((pts, data))
                if self.captionQueue.count > 300 { self.captionQueue.removeFirst(100) }
                self.captionLock.unlock()
            },
            seeked: { [weak self] _ in
                guard let self, self.isCurrent(gen) else { return }
                self.resetAfterSeek()
            },
            eof: { [weak self] in
                guard let self, self.isCurrent(gen) else { return }
                // 読み込みは終わったが、再生はあと数秒続く。少し待ってから「終了」とする
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let self, self.isCurrent(gen) else { return }
                    self.reachedEnd = true
                }
            },
            finished: { [weak self] error in
                guard let self, self.isCurrent(gen) else { return }
                DispatchQueue.main.async {
                    if let error { self.state = .failed(error.localizedDescription) }
                }
            })
        let p = TSPipeline(url: url, callbacks: callbacks)
        p.isFileMode = file
        p.audioOnly = audioOnly
        p.audioMode = audioMode
        pipeline = p
        p.start()
    }

    func stop() {
        // 世代を進めて、throttle() で待っている読み込みスレッドを確実に抜けさせる
        genLock.lock(); generation += 1; genLock.unlock()
        captionTimer?.invalidate(); captionTimer = nil
        positionTimer?.invalidate(); positionTimer = nil
        captionLock.lock(); captionQueue.removeAll(); captionLock.unlock()
        pipeline?.stop()
        pipeline = nil
        synchronizer.setRate(0, time: .zero)
        audioRenderer.flush()
        videoRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        state = .idle
    }

    /// 映像の再生位置に届いた字幕を、PTS の順に渡す（管理データ等で表示が消えないよう、間引かず全部渡す）
    /// データ切れ（読み込みが再生に追いつけない）を見張る。切れたら時計を止めて 1 秒ぶん貯め直し、
    /// 貯まったら再開する。ライブも録画も共通
    private func checkStall() {
        clockLock.lock()
        let started = clockStarted, paused = pausedFlag, seeking = seekPendingFlag
        let end = mediaEnd, wasStalled = stalled, rate = Float(speedValue)
        clockLock.unlock()
        guard started, !paused, !seeking, !reachedEnd else { return }
        let now = synchronizer.currentTime().seconds
        guard now.isFinite, end > 0 else { return }
        let buffered = end - now
        if !wasStalled {
            // 録画の最後まで読み終えたあとは、残りを再生し切るだけなので止めない
            if buffered < 0.05, !(isFile && effectiveDuration > 0 && end - startTime >= effectiveDuration - 1.0) {
                clockLock.lock(); stalled = true; clockLock.unlock()
                synchronizer.rate = 0
                DebugLog.log("player", "データ切れ: 時計を止めた buffered=\(String(format: "%.2f", buffered))s")
                state = .buffering
            }
        } else if buffered >= 1.0 {
            clockLock.lock(); stalled = false; clockLock.unlock()
            synchronizer.rate = rate
            DebugLog.log("player", "再開 buffered=\(String(format: "%.2f", buffered))s")
            state = .playing
        }
    }

    private func pumpCaptions() {
        let now = synchronizer.currentTime().seconds
        guard now.isFinite, synchronizer.rate > 0 else { return }
        captionLock.lock()
        let due = captionQueue.filter { $0.pts <= now }
        if !due.isEmpty { captionQueue.removeAll { $0.pts <= now } }
        captionLock.unlock()
        if !due.isEmpty { captionHandler?(due.map(\.data)) }
    }

    var isMuted: Bool {
        get { audioRenderer.isMuted }
        set { audioRenderer.isMuted = newValue; objectWillChange.send() }
    }

    // MARK: - Enqueue（パイプラインスレッド）

    private func setExpectAudio(_ v: Bool) {
        clockLock.lock(); expectAudio = v; clockLock.unlock()
    }

    /// 録画（ファイル）はネットワークから再生より速く読めてしまう。デコード済みの映像・音声が再生位置より
    /// `maxAhead` 秒以上先に溜まったら、読み込みスレッドをここで待たせる（待たないとメモリが膨らみ続けて落ちる）。
    /// クロック開始前は待たない（開始に必要な分を貯めるため）。stop() / 次の play() で世代が進めば抜ける
    private static let maxAhead: Double = 2.0
    private func throttle(_ pts: CMTime, gen: Int) {
        while isCurrent(gen) {
            clockLock.lock(); let started = clockStarted; let seeking = seekPendingFlag; let isStalled = stalled; clockLock.unlock()
            // シーク要求が来ているときは待たずに抜ける（読み込みスレッドが要求を拾えるように）。
            // データ切れで時計を止めている間も待たない（止まった時計基準で待つと、遅い方が貯まらず再開できなくなる）
            guard started, !seeking, !isStalled else { return }
            let ahead = pts.seconds - synchronizer.currentTime().seconds
            if !ahead.isFinite || ahead < Self.maxAhead { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func enqueueVideo(_ sb: CMSampleBuffer) {
        if videoRenderer.status == .failed {
            videoRenderer.flush()
        }
        videoRenderer.enqueue(sb)
        clockLock.lock()
        sawVideo = true
        videoEnd = max(videoEnd, Self.endSeconds(sb))
        let shouldStartVideoOnly = !clockStarted && !expectAudio
        if shouldStartVideoOnly { clockStarted = true }
        clockLock.unlock()
        if shouldStartVideoOnly {
            startClock(at: sb.presentationTimeStamp - CMTime(seconds: startupBuffer, preferredTimescale: 90_000))
        }
    }

    private func enqueueAudio(_ sb: CMSampleBuffer) {
        audioRenderer.enqueue(sb)
        let pts = sb.presentationTimeStamp
        clockLock.lock()
        audioEnd = max(audioEnd, Self.endSeconds(sb))
        if firstAudioPTS == nil { firstAudioPTS = pts }
        var startAt: CMTime?
        if !clockStarted, sawVideo || audioOnlyMode, let first = firstAudioPTS,
           (pts - first).seconds >= startupBuffer {
            clockStarted = true
            startAt = first
        }
        clockLock.unlock()
        if let startAt { startClock(at: startAt) }
    }

    /// サンプルの末尾の時刻。映像は duration が無い（invalid）ので PTS そのもの
    private static func endSeconds(_ sb: CMSampleBuffer) -> Double {
        let pts = sb.presentationTimeStamp.seconds
        let d = sb.duration.seconds
        return d.isFinite && d > 0 ? pts + d : pts
    }

    private func startClock(at time: CMTime) {
        clockLock.lock()
        let rate: Float = pausedFlag ? 0 : Float(speedValue)
        clockLock.unlock()
        synchronizer.setRate(rate, time: time)
        DispatchQueue.main.async { [weak self] in
            self?.seekTarget = nil
            self?.state = .playing
        }
    }

    // MARK: - 録画の操作（メインスレッド）

    private var effectiveDuration: Double { duration > 0 ? duration : (durationHint ?? 0) }

    /// 先頭からの秒数へシーク。末尾の約 2 秒手前までに丸める（TvtPlay と同じ）
    func seek(to seconds: Double) {
        guard isFile, isSeekable else { return }
        let target = min(max(seconds, 0), max(effectiveDuration - 2, 0))
        seekTarget = target
        position = target
        reachedEnd = false
        state = .buffering
        setPaused(false)
        clockLock.lock(); seekPendingFlag = true; clockLock.unlock()
        pipeline?.requestSeek(startTime + target)
    }

    func seek(by delta: Double) { seek(to: position + delta) }

    func setPaused(_ paused: Bool) {
        clockLock.lock()
        pausedFlag = paused
        let started = clockStarted
        let rate = Float(speedValue)
        let isStalled = stalled
        clockLock.unlock()
        isPaused = paused
        if started { synchronizer.rate = (paused || isStalled) ? 0 : rate }
    }

    func togglePause() { setPaused(!isPaused) }

    /// 再生速度（0.5〜2.0）。音程は変えない
    func setSpeed(_ speed: Double) {
        clockLock.lock()
        speedValue = speed
        let started = clockStarted
        let paused = pausedFlag || stalled
        clockLock.unlock()
        playbackRate = speed
        audioRenderer.audioTimePitchAlgorithm = .timeDomain
        if started && !paused { synchronizer.rate = Float(speed) }
    }

    /// パイプラインがシークを終えた（読み込み位置が変わった）。描画側のバッファを捨てて時計を取り直す
    private func resetAfterSeek() {
        audioRenderer.flush()
        videoRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
        synchronizer.setRate(0, time: .zero)
        clockLock.lock()
        clockStarted = false; firstAudioPTS = nil; sawVideo = false; seekPendingFlag = false; audioEnd = 0; videoEnd = 0; stalled = false
        clockLock.unlock()
        captionLock.lock(); captionQueue.removeAll(); captionLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.state = .buffering
            self?.reachedEnd = false
        }
    }

    private func pumpPosition() {
        if let t = seekTarget { position = t; return }
        clockLock.lock(); let started = clockStarted; clockLock.unlock()
        guard started else { return }
        let now = synchronizer.currentTime().seconds
        guard now.isFinite else { return }
        let upper = effectiveDuration > 0 ? effectiveDuration : Double.greatestFiniteMagnitude
        position = min(max(now - startTime, 0), upper)
    }
}
