import Foundation
import ActivityKit

/// ロック画面・Dynamic Island の「再生中」（ライブアクティビティ）を出す・更新する・消す。
/// 再生画面を開いている間だけ 1 つ出す（局を替えても同じものを更新）。設定でオフにできる。
///
/// 持ち主（いま前に出ている再生画面の TVNowPlaying）だけが更新・終了できる。新しい再生画面の onAppear が
/// 古い画面の onDisappear より先に来ても、古い画面の終了で新しい画面のアクティビティが消えないように
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<NowPlayingAttributes>?
    private var owner: ObjectIdentifier?
    /// 新しく出してよいか。再生画面を開いたとき（begin）だけ true。ユーザーが消した・iOS が終わらせたあとは出し直さない
    private var mayStart = false
    private var last: NowPlayingAttributes.ContentState?
    private var lastSent = Date.distantPast

    var enabled: Bool {
        UserDefaults.standard.object(forKey: "liveActivity") as? Bool ?? true
    }

    /// 再生画面を開いた。前の持ち主のアクティビティが残っていれば引き継ぐ
    func begin(owner o: ObjectIdentifier) {
        owner = o
        mayStart = true
        last = nil
        if activity == nil {
            // 前回アプリが落ちて残ったもの
            for a in Activity<NowPlayingAttributes>.activities { Task { await a.end(nil, dismissalPolicy: .immediate) } }
        }
    }

    func update(_ state: NowPlayingAttributes.ContentState, owner o: ObjectIdentifier) {
        guard o == owner else { return }
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else { endActivity(); return }
        // 同じ内容（日時の数秒のずれは同じとみなす）なら送らない。送りすぎるとシステムに間引かれる
        if let last, Self.same(last, state), Date().timeIntervalSince(lastSent) < 60 { return }
        if let activity {
            switch activity.activityState {
            case .active, .stale:
                last = state
                lastSent = Date()
                let content = ActivityContent(state: state, staleDate: nil)
                Task { await activity.update(content) }
                return
            default:
                // ユーザーが消した・時間切れ → この再生画面の間はもう出さない
                self.activity = nil
                mayStart = false
            }
        }
        guard mayStart else { return }
        // 始められるのはアプリが前面にあるときだけ。背面からは失敗するので、次の更新でもう一度試す
        do {
            activity = try Activity.request(attributes: NowPlayingAttributes(started: Date()),
                                            content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            mayStart = false
            last = state
            lastSent = Date()
        } catch {
            DebugLog.log("activity", "ライブアクティビティを始められません: \(error.localizedDescription)")
        }
    }

    /// 再生画面を閉じた（持ち主のときだけ消す）
    func end(owner o: ObjectIdentifier) {
        guard o == owner else { return }
        owner = nil
        mayStart = false
        endActivity()
    }

    /// 設定でオフにした
    func disable() {
        mayStart = false
        endActivity()
    }

    /// 設定でオンに戻した: 次の更新で出してよい
    func allowRestart() {
        if owner != nil && activity == nil { mayStart = true; last = nil }
    }

    private func endActivity() {
        last = nil
        guard let a = activity else { return }
        activity = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }

    private static func same(_ a: NowPlayingAttributes.ContentState, _ b: NowPlayingAttributes.ContentState) -> Bool {
        func near(_ x: Date?, _ y: Date?) -> Bool {
            switch (x, y) {
            case (nil, nil): true
            case let (x?, y?): abs(x.timeIntervalSince(y)) < 3
            default: false
            }
        }
        func nearD(_ x: Double?, _ y: Double?, _ tol: Double) -> Bool {
            switch (x, y) {
            case (nil, nil): true
            case let (x?, y?): abs(x - y) < tol
            default: false
            }
        }
        return a.kind == b.kind && a.channel == b.channel && a.title == b.title && a.isPaused == b.isPaused
            && near(a.start, b.start) && near(a.end, b.end) && nearD(a.behindSeconds, b.behindSeconds, 10)
            && nearD(a.pausedProgress, b.pausedProgress, 0.01)
    }
}
