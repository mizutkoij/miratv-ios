import AVFoundation
import SwiftUI
import Network

/// EPGStation の変換配信（HLS）を AVPlayer で再生する。
/// 原画質（Mirakurun の MPEG-2 TS）は自前の FFmpeg エンジンで再生するため、これは「高画質変換」「省データ」用
final class HLSPlayback: ObservableObject {
    enum State: Equatable { case idle, loading, playing, failed(String) }

    @Published private(set) var state: State = .idle
    let player = AVPlayer()
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    func play(url: URL) { play(url: url, headers: nil) }

    /// headers: 配信元が Referer などを見るときの追加ヘッダー（AVURLAsset の HTTP ヘッダー指定）
    func play(url: URL, headers: [String: String]?) {
        stop()
        state = .loading
        let item: AVPlayerItem
        if let headers {
            item = AVPlayerItem(asset: AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers]))
        } else {
            item = AVPlayerItem(url: url)
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch item.status {
                case .readyToPlay: self.state = .playing
                case .failed: self.state = .failed(describeError(item.error ?? URLError(.cannotLoadFromNetwork)))
                default: break
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    func stop() {
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        state = .idle
    }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue; objectWillChange.send() }
    }
}

/// AVPlayerLayer を貼るだけの UIView
struct PlayerLayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ uiView: LayerView, context: Context) {}

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// 回線の種類（モバイル回線では自動で省データにする設定用）
final class NetworkKind: ObservableObject {
    @Published private(set) var isExpensive = false
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.isExpensive = path.isExpensive }
        }
        monitor.start(queue: DispatchQueue(label: "MiraTV.NetworkKind"))
    }

    deinit { monitor.cancel() }
}
