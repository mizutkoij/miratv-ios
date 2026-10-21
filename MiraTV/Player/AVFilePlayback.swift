import AVFoundation
import AVKit
import SwiftUI
import Photos
import CoreImage

/// mp4 など iOS が自分で読めるファイルを AVPlayer で再生する。
/// 標準の再生画面（AVPlayerViewController）は使わず、TS と同じ自前の画面（縦・横の全画面・シークバー・写真・録画・PiP）で操作する。
///
/// - 写真: AVPlayerItemVideoOutput から今の 1 枚を取る（取れなければ AVAssetImageGenerator）
/// - 録画: 押した位置ともう一度押した位置を覚えて、その区間を元のファイルから切り出す（AVAssetExportSession）。
///   mp4 は H.264 / HEVC のままなので、作り直さずにそのまま写真に保存できる（TS のように 1 枚ずつ描き直さない）。
///   背面に回っても PiP でも続けられる。切り出すときに nzb-dl から読み直すので、長いほど保存に時間がかかる
final class AVFilePlayback: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    enum State: Equatable { case idle, loading, buffering, playing, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPaused = false
    @Published private(set) var playbackRate: Double = 1
    @Published private(set) var reachedEnd = false
    /// 映像の縦横比（presentationSize から）
    @Published private(set) var displayAspect: CGFloat = 16.0 / 9.0
    /// 映像があるか（音声だけのファイルなら false）
    @Published private(set) var hasVideo = true
    @Published private(set) var pipPossible = false
    @Published private(set) var pipActive = false
    /// 録画の開始位置（秒）。録っていなければ nil
    @Published private(set) var clipStart: Double?
    /// この item で一度でも実際に再生が進んだか（読めない投稿を再投稿へ切り替えるかの判断に使う）
    @Published private(set) var hasPlayed = false

    /// これを超えたら自動で止める（TS の録画と同じ上限）
    static let maxClipSeconds: Double = ClipRecorder.maxSeconds

    let player = AVPlayer()
    let playerLayer = AVPlayerLayer()
    private(set) var asset: AVURLAsset?
    private var output: AVPlayerItemVideoOutput?
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var pip: AVPictureInPictureController?
    private var pipObservation: NSKeyValueObservation?
    /// 読み込みが終わったら飛ぶ位置（続きから）
    private var pendingSeek: Double?
    private static let ciContext = CIContext()
    /// 開くたびに増える。前の item の遅れて届いた通知を捨てるため
    private var generation = 0

    override init() {
        super.init()
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { [weak self] t in self?.tick(t) }
        if AVPictureInPictureController.isPictureInPictureSupported(),
           let c = AVPictureInPictureController(playerLayer: playerLayer) {
            c.delegate = self
            c.canStartPictureInPictureAutomaticallyFromInline = true
            pip = c
            pipObservation = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
                let v = c.isPictureInPicturePossible
                DispatchQueue.main.async { self?.pipPossible = v }
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: - 再生

    /// mime: URL に拡張子が無い（nzb-dl の /api/stream/<id>）ので、中身の種類を教える
    func play(url: URL, mime: String, resume: Double?) {
        stop()
        generation += 1
        let gen = generation
        state = .loading
        hasPlayed = false
        hasVideo = mime.hasPrefix("video")
        let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: mime])
        self.asset = asset
        let item = AVPlayerItem(asset: asset)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(out)
        output = out
        observations = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let status = item.status, err = item.error
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    self.statusChanged(status, err)
                }
            },
            item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
                let s = item.presentationSize
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    if s.width > 0, s.height > 0 { self.displayAspect = s.width / s.height }
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
                let s = p.timeControlStatus
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    self.controlChanged(s)
                }
            },
        ]
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            self?.reachedEnd = true
            self?.isPaused = true
        }
        pendingSeek = resume
        player.replaceCurrentItem(with: item)
        player.defaultRate = Float(playbackRate)
        player.play()
        isPaused = false
    }

    func stop() {
        generation += 1
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
        player.pause()
        player.replaceCurrentItem(with: nil)
        observations = []
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        output = nil
        asset = nil
        pendingSeek = nil
        clipStart = nil
        state = .idle
        position = 0
        duration = 0
        reachedEnd = false
    }

    private func statusChanged(_ status: AVPlayerItem.Status, _ error: Error?) {
        switch status {
        case .readyToPlay:
            updateDuration()
            if let t = pendingSeek { pendingSeek = nil; seek(to: t) }
            // 読み込み中に一時停止していたら、読み込みは終わっているので「読み込み中」を出し続けない
            if state == .loading { state = player.timeControlStatus == .paused ? .playing : .buffering }
        case .failed:
            state = .failed(describeError(error ?? URLError(.cannotDecodeContentData)))
        default:
            break
        }
    }

    private func controlChanged(_ s: AVPlayer.TimeControlStatus) {
        if case .failed = state { return }
        // isPaused は実際の状態に合わせる（PiP の再生ボタン・イヤホンを外した・電話などで止まることがある）
        switch s {
        case .playing:
            state = .playing
            isPaused = false
            hasPlayed = true
        case .waitingToPlayAtSpecifiedRate:
            if state != .loading { state = .buffering }
            isPaused = false
        case .paused:
            isPaused = true
            // 一時停止は「読み込み中」ではない（読み込みが終わっていれば。最初の読み込み中ならそのまま）
            if state == .buffering, player.currentItem?.status == .readyToPlay { state = .playing }
        @unknown default:
            break
        }
    }

    private func updateDuration() {
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
    }

    private func tick(_ t: CMTime) {
        let s = t.seconds
        guard s.isFinite else { return }
        position = s
        if duration == 0 { updateDuration() }
        // 終わりから戻した
        if reachedEnd, duration > 0, s < duration - 1 { reachedEnd = false }
    }

    // MARK: - 操作

    func seek(to seconds: Double) {
        guard player.currentItem?.status == .readyToPlay else { pendingSeek = seconds; return }
        // 録画の途中でシークしたら、その録画は取り消す（ロック画面・PiP のスキップでも区間がずれないように）
        clipStart = nil
        let t = duration > 0 ? min(max(seconds, 0), max(duration - 1, 0)) : max(seconds, 0)
        position = t
        reachedEnd = false
        // 手前は 1 秒まで許す（キーフレームに合わせられるので、Usenet から読む量が減る）。後ろには行き過ぎない
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600), toleranceAfter: .zero)
    }

    func seek(by delta: Double) { seek(to: position + delta) }

    func setPaused(_ paused: Bool) {
        if paused {
            player.pause()
        } else {
            if reachedEnd { seek(to: 0) }
            player.playImmediately(atRate: Float(playbackRate))
        }
        isPaused = paused
    }

    func togglePause() { setPaused(!isPaused) }

    func setSpeed(_ speed: Double) {
        playbackRate = speed
        player.defaultRate = Float(speed)
        if !isPaused { player.rate = Float(speed) }
    }

    // MARK: - PiP

    func togglePiP() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.pipActive = true }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.pipActive = false }
    }

    // MARK: - 写真

    /// いま映っている 1 枚
    func captureImage() async -> UIImage? {
        let time = player.currentTime()
        if let output, let pb = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            let ci = CIImage(cvPixelBuffer: pb)
            if let cg = Self.ciContext.createCGImage(ci, from: ci.extent) { return UIImage(cgImage: cg) }
        }
        // 一時停止中などで新しい 1 枚が来ていないときは、ファイルからその位置の 1 枚を作る
        guard let asset else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        guard let r = try? await gen.image(at: time) else { return nil }
        return UIImage(cgImage: r.image)
    }

    // MARK: - 録画（区間を切り出して写真へ）

    /// いまの位置から録り始める。準備ができていなければ false
    func startClip() -> Bool {
        guard asset != nil, duration > 0, clipStart == nil else { return false }
        clipStart = position
        return true
    }

    /// 録っている秒数（ボタンの表示用）
    var clipSeconds: Double {
        guard let s = clipStart else { return 0 }
        return max(position - s, 0)
    }

    func cancelClip() { clipStart = nil }

    /// 止めて、その区間を写真に保存する。結果の一言を返す
    @MainActor func finishClip() async -> String {
        guard let r = takeClipRange() else { return "" }
        guard r.to - r.from >= 1 else { return "短すぎるので保存しませんでした（1 秒以上）" }
        return await Self.saveClip(asset: r.asset, from: r.from, to: r.to)
    }

    /// 録画を止めて、保存する区間を返す（すぐ返る。閉じる直前でも区間を失わないように、保存は呼び出し側で）
    func takeClipRange() -> (asset: AVURLAsset, from: Double, to: Double)? {
        guard let start = clipStart, let asset else { clipStart = nil; return nil }
        clipStart = nil
        return (asset, start, min(position, start + Self.maxClipSeconds))
    }

    /// 区間を元のファイルから切り出して写真に保存する。結果の一言を返す
    static func saveClip(asset: AVURLAsset, from: Double, to: Double) async -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return "写真への保存が許可されていません（設定 › プライバシー › 写真）"
        }
        let range = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                                end: CMTime(seconds: to, preferredTimescale: 600))
        var lastError = "書き出せませんでした"
        // まずはそのまま切り出す（速い・画質そのまま）。写真が受け付けない中身なら、作り直して試す
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mp4")
            session.outputURL = url
            session.outputFileType = .mp4
            session.timeRange = range
            session.shouldOptimizeForNetworkUse = true
            await session.export()
            guard session.status == .completed else {
                lastError = session.error.map { describeError($0) } ?? "書き出せませんでした"
                DebugLog.log("clip", "mp4 の切り出しに失敗（\(preset)）: \(lastError)")
                try? FileManager.default.removeItem(at: url)
                continue
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                try? FileManager.default.removeItem(at: url)
                return "動画を写真に保存しました"
            } catch {
                lastError = error.localizedDescription
                DebugLog.log("clip", "写真に保存できなかった（\(preset)）: \(lastError)")
                try? FileManager.default.removeItem(at: url)
            }
        }
        return "保存できませんでした: \(lastError)"
    }
}

/// AVPlayerLayer を自前の画面に貼る（VideoSurface と同じく、全画面 ⇄ ミニの切り替えで 1 つのレイヤーを付け替える）
struct AVLayerSurface: UIViewRepresentable {
    let layer: AVPlayerLayer

    func makeUIView(context: Context) -> VideoSurface.HostView {
        let v = VideoSurface.HostView()
        v.backgroundColor = .black
        v.attach(layer)
        return v
    }

    func updateUIView(_ uiView: VideoSurface.HostView, context: Context) {}

    static func dismantleUIView(_ v: VideoSurface.HostView, coordinator: ()) {
        if v.videoLayer?.superlayer === v.layer { v.videoLayer?.removeFromSuperlayer() }
        v.releaseLayer()
    }
}
