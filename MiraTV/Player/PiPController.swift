import AVFoundation
import AVKit
import Combine

/// AVSampleBufferDisplayLayer を使う自前プレイヤーの PiP。
/// - ライブ: 再生位置は無限幅の範囲で返し、一時停止・スキップは受け付けない
/// - 録画（`fileControls` を設定）: PiP のウィンドウにもシークバー・一時停止・±15 秒を出す
final class PiPController: NSObject, ObservableObject,
                            AVPictureInPictureControllerDelegate,
                            AVPictureInPictureSampleBufferPlaybackDelegate {

    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false

    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?

    /// 録画のときだけ渡す。時刻は映像のサンプルと同じ時計（PTS 秒）
    struct FileControls {
        var timeRange: () -> CMTimeRange
        var isPaused: () -> Bool
        var setPlaying: (Bool) -> Void
        var skip: (Double) -> Void
    }

    var fileControls: FileControls? {
        didSet { refresh() }
    }

    /// 一時停止・長さ・シークが変わったら呼ぶ（PiP のウィンドウの表示を取り直させる）
    func refresh() {
        DispatchQueue.main.async { self.controller?.invalidatePlaybackState() }
    }

    init(layer: AVSampleBufferDisplayLayer) {
        super.init()
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        controller = c
        possibleObservation = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] ctrl, _ in
            DispatchQueue.main.async { self?.isPossible = ctrl.isPictureInPicturePossible }
        }
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
        else { controller.startPictureInPicture() }
    }

    // MARK: AVPictureInPictureControllerDelegate

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.isActive = true }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.isActive = false }
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate

    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        fileControls?.setPlaying(playing)
        refresh()
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        fileControls?.timeRange() ?? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        fileControls?.isPaused() ?? false
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        fileControls?.skip(skipInterval.seconds)
        completionHandler()
    }
}
