import Foundation
import UIKit
import Photos
import MediaPlayer

// MARK: - 録画の続きから再生

/// 録画ごとに「どこまで見たか」を覚える（端末の UserDefaults）。最後まで見たら消す
enum WatchPositions {
    private static let key = "watchPositions.v1"
    /// これより前でやめたものは覚えない（開いてすぐ閉じた、など）
    static let minimumSeconds: Double = 15
    /// 残りがこれ未満なら「見終わった」扱いで消す
    static let finishedRemaining: Double = 90

    private static var all: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func position(_ recordedId: Int) -> Double? { position(key: String(recordedId)) }

    /// 録画以外（Usenet のアーカイブ "nzb-<id>" など）も同じ仕組みで覚える
    static func position(key: String) -> Double? { all[key] }

    /// 続きの位置を覚えているもののキー（一覧の「続きから」の絞り込み用。1 回の読み出しで全部）
    static var savedKeys: Set<String> { Set(all.keys) }

    /// 0〜1（一覧のバー用）
    static func progress(_ recordedId: Int, duration: Double) -> Double? {
        guard let p = position(recordedId), duration > 0 else { return nil }
        return min(max(p / duration, 0), 1)
    }

    static func save(_ recordedId: Int, position: Double, duration: Double) {
        save(key: String(recordedId), position: position, duration: duration)
    }

    static func save(key: String, position: Double, duration: Double) {
        guard position.isFinite else { return }
        var a = all
        if position < minimumSeconds || (duration > 0 && duration - position < finishedRemaining) {
            a.removeValue(forKey: key)
        } else {
            a[key] = position
        }
        if a.count > 300 { a = Dictionary(uniqueKeysWithValues: a.suffix(200).map { ($0.key, $0.value) }) }
        all = a
    }
}

// MARK: - 画面のキャプチャ

enum CaptureSaver {
    /// 写真ライブラリに追加する（読み取りの許可は要らない「追加のみ」）。結果の一言を返す
    static func save(_ image: UIImage) async -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return "写真への保存が許可されていません（設定 › プライバシー › 写真）" }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return "写真に保存しました"
        } catch {
            return "保存できませんでした: \(error.localizedDescription)"
        }
    }
}

// MARK: - ロック画面・コントロールセンターの「再生中」（テレビ）

/// テレビの再生中の情報をロック画面に出し、再生 / 停止ボタンを受け付ける。ラジオの RadioPlayer と同じ仕組み
@MainActor
final class TVNowPlaying {
    private var targets: [(MPRemoteCommand, Any)] = []

    private var paused = false

    /// onPlay / onPause: ロック画面の再生・一時停止。onSkip: ±秒（録画のみ。ライブは nil）
    func activate(onPlay: @escaping () -> Void, onPause: @escaping () -> Void, onSkip: ((Double) -> Void)?) {
        deactivate()
        LiveActivityController.shared.begin(owner: ObjectIdentifier(self))
        let c = MPRemoteCommandCenter.shared()
        targets.append((c.togglePlayPauseCommand, c.togglePlayPauseCommand.addTarget { [weak self] _ in
            if self?.paused == true { onPlay() } else { onPause() }
            return .success
        }))
        targets.append((c.playCommand, c.playCommand.addTarget { _ in onPlay(); return .success }))
        targets.append((c.pauseCommand, c.pauseCommand.addTarget { _ in onPause(); return .success }))
        // ラジオ用に登録されているシークバー・次へは、テレビの間は出さない（押してもラジオ側が空振りするだけなので）
        c.changePlaybackPositionCommand.isEnabled = false
        c.nextTrackCommand.isEnabled = false
        c.skipForwardCommand.isEnabled = onSkip != nil
        c.skipBackwardCommand.isEnabled = onSkip != nil
        if let onSkip {
            c.skipForwardCommand.preferredIntervals = [30]
            c.skipBackwardCommand.preferredIntervals = [15]
            targets.append((c.skipForwardCommand, c.skipForwardCommand.addTarget { _ in onSkip(30); return .success }))
            targets.append((c.skipBackwardCommand, c.skipBackwardCommand.addTarget { _ in onSkip(-15); return .success }))
        }
    }

    /// programStart / programEnd: ライブの番組の時間（Dynamic Island のバー用）。behind: 追っかけ再生でライブより何秒遅れか
    func update(title: String, channel: String, artworkURL: URL?, isLive: Bool,
                position: Double? = nil, duration: Double? = nil, rate: Double = 1,
                programStart: Date? = nil, programEnd: Date? = nil, behind: Double? = nil) {
        paused = rate == 0
        updateActivity(title: title, channel: channel, isLive: isLive, position: position, duration: duration,
                       rate: rate, programStart: programStart, programEnd: programEnd, behind: behind)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title.isEmpty ? channel : title,
            MPMediaItemPropertyArtist: channel,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let position { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position }
        if let duration, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let url = artworkURL, let img = ImageStore.shared.cached(url) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateActivity(title: String, channel: String, isLive: Bool, position: Double?, duration: Double?,
                                rate: Double, programStart: Date?, programEnd: Date?, behind: Double?) {
        let kind: NowPlayingAttributes.Kind = isLive ? .live : (behind != nil ? .timeshift : .recorded)
        var state = NowPlayingAttributes.ContentState(kind: kind, channel: channel, title: title, isPaused: rate == 0,
                                                      start: programStart, end: programEnd, pausedProgress: nil,
                                                      behindSeconds: behind)
        if kind == .recorded, let position, let duration, duration > 0, position.isFinite {
            // 録画: いまの位置から逆算した「始まった時刻」と「終わる時刻」（再生速度ぶん縮める）
            let r = rate > 0 ? rate : 1
            let start = Date().addingTimeInterval(-position / r)
            state.start = start
            state.end = start.addingTimeInterval(duration / r)
            state.pausedProgress = min(max(position / duration, 0), 1)
        } else if let s = programStart, let e = programEnd, e > s {
            // 追っかけ: 見ているのは遅れた分だけ前なので、バーもその分ずらす
            let lag = behind ?? 0
            state.start = s.addingTimeInterval(lag)
            state.end = e.addingTimeInterval(lag)
            state.pausedProgress = min(max((Date().timeIntervalSince(s) - lag) / e.timeIntervalSince(s), 0), 1)
        }
        LiveActivityController.shared.update(state, owner: ObjectIdentifier(self))
    }

    func deactivate() {
        LiveActivityController.shared.end(owner: ObjectIdentifier(self))
        let c = MPRemoteCommandCenter.shared()
        for (cmd, token) in targets { cmd.removeTarget(token) }
        targets.removeAll()
        // ラジオが使うものは元に戻す
        c.changePlaybackPositionCommand.isEnabled = true
        c.nextTrackCommand.isEnabled = true
        c.skipForwardCommand.isEnabled = true
        c.skipBackwardCommand.isEnabled = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
