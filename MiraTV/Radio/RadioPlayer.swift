import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

/// ラジオ専用プレイヤー。TV の PlayerEngine とは別系統（AVPlayer ベース）。
/// - ライブ: HLS / Icecast をそのまま
/// - アーカイブ: play トークン取得（初回 ~45 秒）→ audio/mp4 を Range 再生、シーク可
/// ロック画面・コントロールセンター・バックグラウンド再生に対応。
@MainActor
final class RadioPlayer: ObservableObject {

    enum Mode: Equatable {
        case idle
        case live(stationKey: String)
        case archive(nzb: String)
    }

    enum Phase: Equatable {
        case idle
        /// アーカイブ初回の remux 待ちなど。UI はスピナー＋経過秒を出す
        case preparing(since: Date)
        case buffering
        case playing
        case paused
        case failed(String)
    }

    struct NowInfo: Equatable {
        var stationName = ""
        var title = ""
        var performer = ""
        var artworkURL: URL?
    }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var now = NowInfo()
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0

    /// サーバーが前番組の末尾 25 秒を頭に継ぎ足すので、番組開始位置へ飛ばす
    static let archiveHeadStitch: Double = 25

    private let player = AVPlayer()
    private var resolver: RadioStreamResolver?
    private var timeObserver: Any?
    private var bag = Set<AnyCancellable>()
    private var itemBag = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?

    // アーカイブの連続再生
    private var archiveQueue: [RadioScheduleItem] = []
    private var currentArchive: RadioScheduleItem?
    /// 継ぎ足しの有無を判定する許容誤差（秒）。番組表の長さ + 25 秒前後ならスティッチ済み
    private static let stitchTolerance: Double = 10
    private var archiveRetried = false

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = t.seconds
                self.updateNowPlayingElapsed()
            }
        }
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .playing: self.phase = .playing
                case .waitingToPlayAtSpecifiedRate:
                    if case .preparing = self.phase { break }
                    self.phase = .buffering
                case .paused:
                    if self.phase == .playing || self.phase == .buffering { self.phase = .paused }
                @unknown default: break
                }
            }
            .store(in: &bag)
        setupRemoteCommands()
    }

    func configure(client: RadioWebClient) {
        resolver = RadioStreamResolver(client: client)
    }

    // MARK: - Live

    func playLive(_ station: RadioStation) {
        guard let resolver else { return }
        start(mode: .live(stationKey: station.key))
        now = NowInfo(stationName: station.name,
                      title: station.current?.title ?? "",
                      performer: station.current?.pfm ?? "",
                      artworkURL: (station.current?.img ?? station.logo).flatMap(URL.init(string:)))
        loadTask = Task {
            do {
                switch try await resolver.resolveLive(station) {
                case .avPlayer(let url): self.load(url, startAt: nil)
                case .ffmpeg: throw RadioWebError.unsupported("この局（Ogg 配信）は次のステップで対応します")
                case .unsupported(let why): throw RadioWebError.unsupported(why)
                }
            } catch { self.fail(error) }
        }
    }

    // MARK: - Archive

    /// `queue` に同じ日の後続番組を渡すと、終了時に自動で次へ進み、裏で prefetch もする
    func playArchive(_ item: RadioScheduleItem, stationName: String, queue: [RadioScheduleItem] = []) {
        guard let nzb = item.nzb else { return }
        start(mode: .archive(nzb: nzb))
        currentArchive = item
        archiveQueue = queue.filter(\.isArchived)
        archiveRetried = false
        now = NowInfo(stationName: stationName, title: item.title, performer: item.pfm ?? "",
                      artworkURL: item.thumbnail.flatMap(URL.init(string:)))
        resolveAndLoadArchive(nzb)
    }

    private func resolveAndLoadArchive(_ nzb: String) {
        guard let resolver else { return }
        phase = .preparing(since: Date())
        loadTask = Task {
            do {
                let url = try await resolver.resolveArchive(nzb: nzb)
                guard !Task.isCancelled else { return }
                self.load(url, startAt: Self.archiveHeadStitch)
                if let next = self.archiveQueue.first?.nzb { resolver.client.archivePrefetch(nzb: next) }
            } catch { self.fail(error) }
        }
    }

    private func advanceArchive() {
        guard !archiveQueue.isEmpty else { phase = .paused; return }
        let next = archiveQueue.removeFirst()
        playArchive(next, stationName: now.stationName, queue: archiveQueue)
    }

    // MARK: - Transport

    func togglePause() {
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    func seek(by delta: Double) {
        guard case .archive = mode else { return }
        seek(to: max(0, min(duration, position + delta)))
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        loadTask?.cancel()
        player.replaceCurrentItem(with: nil)
        itemBag.removeAll()
        mode = .idle; phase = .idle; position = 0; duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Internals

    private func start(mode: Mode) {
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemBag.removeAll()
        self.mode = mode
        phase = .buffering
        position = 0; duration = 0
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func load(_ url: URL, startAt: Double?) {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 10

        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] st in
                guard let self else { return }
                if st == .readyToPlay {
                    let d = item.duration.seconds
                    self.duration = d.isFinite ? d : 0
                    if let startAt, self.shouldSkipHead(startAt) { self.seek(to: startAt) }
                    self.updateNowPlaying()
                } else if st == .failed {
                    self.handleItemFailure(item.error)
                }
            }
            .store(in: &itemBag)

        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.advanceArchive() }
            .store(in: &itemBag)

        player.replaceCurrentItem(with: item)
        player.play()
    }

    /// サーバーは前番組の取得や結合に失敗すると黙ってスティッチ無しで返す（server.py のフォールバック）。
    /// その場合に 25 秒飛ばすと番組冒頭を失うので、実際の長さが「番組表の長さ + 25 秒」のときだけ飛ばす。
    /// 番組表の長さが分からないときは従来どおり飛ばす
    private func shouldSkipHead(_ startAt: Double) -> Bool {
        guard duration > startAt + 1 else { return false }
        guard let expected = currentArchive?.lengthSeconds else { return true }
        return abs(duration - (expected + startAt)) <= Self.stitchTolerance
    }

    /// アーカイブのトークンはサーバー再起動・1 時間無アクセスで失効（404）→ 1 回だけ play を取り直す
    private func handleItemFailure(_ error: Error?) {
        if case .archive(let nzb) = mode, !archiveRetried {
            archiveRetried = true
            resolveAndLoadArchive(nzb)
            return
        }
        fail(error ?? URLError(.cannotLoadFromNetwork))
    }

    private func fail(_ error: Error) {
        guard !(error is CancellationError) else { return }
        phase = .failed(describeError(error))
    }

    // MARK: - Now Playing / Remote

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: now.title.isEmpty ? now.stationName : now.title,
            MPMediaItemPropertyArtist: now.performer.isEmpty ? now.stationName : now.performer,
            MPMediaItemPropertyAlbumTitle: now.stationName,
            MPNowPlayingInfoPropertyPlaybackRate: player.rate,
        ]
        if case .live = mode {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        } else {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadArtwork()
    }

    private func updateNowPlayingElapsed() {
        guard case .archive = mode, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork() {
        guard let url = now.artworkURL else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = art
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.player.play(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePause(); return .success }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { [weak self] _ in self?.seek(by: 30); return .success }
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.seek(by: -15); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime); return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.advanceArchive(); return .success }
    }
}
