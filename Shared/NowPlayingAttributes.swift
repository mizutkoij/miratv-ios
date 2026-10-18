import Foundation
import ActivityKit

/// ロック画面・Dynamic Island に出す「再生中」（ライブアクティビティ）。アプリとウィジェット拡張の両方で使う
struct NowPlayingAttributes: ActivityAttributes {
    enum Kind: String, Codable, Hashable { case live, timeshift, recorded }

    struct ContentState: Codable, Hashable {
        var kind: Kind
        var channel: String
        var title: String
        var isPaused: Bool
        /// 進み具合のバーの始まりと終わり。ライブは番組の開始・終了、録画は「いまの位置から逆算した開始」と終了
        var start: Date?
        var end: Date?
        /// 一時停止中に出す位置（0〜1）
        var pausedProgress: Double?
        /// 追っかけ再生でライブより何秒遅れているか
        var behindSeconds: Double?
    }

    /// ずっと変わらないもの（いまは無し。局を替えても同じアクティビティを使い回す）
    var started: Date
}
