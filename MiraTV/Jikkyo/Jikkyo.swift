import Foundation
import Combine

// ニコニコ実況のコメントを、映像に重ねて流す。
// - 録画: ニコニコ実況 過去ログ API（非公式・個人運営、https://jikkyo.tsukumijima.net）
//     GET /api/kakolog/{jkID}?starttime=<unix>&endtime=<unix>&format=json  （一度に 3 日まで）
//     5 分ごとに収集されるので、放送直後の録画は最後の数分ぶんがまだ無いことがある
// - ライブ: NX-Jikkyo（ニコニコ実況互換のコメントサーバー、ニコニコ実況のコメントも取り込んでいる）
//     wss://nx-jikkyo.tsukumijima.net/api/v1/channels/{jkID}/ws/watch → room で受け取った URI に
//     ニコ生互換のコメント受信セッションをつなぐ
// どちらも読み取りだけ（投稿はしない）。

struct JikkyoComment: Hashable {
    /// 書き込まれた時刻（UNIX 秒、小数あり）
    let time: Double
    let text: String
    /// ニコニコのコマンド（"ue" "shita" "big" "small" "red" など、空白区切り）
    let mail: String
}

// MARK: - 局 → 実況 ID

enum JikkyoChannel {
    /// BS は実況 ID の数字がサービス ID と同じ（jk101 = NHK BS、jk141 = BS日テレ …）
    private static let bsIDs: Set<Int> = [101, 103, 141, 151, 161, 171, 181, 191, 192, 193, 200, 201, 211, 222, 236, 252, 260, 263, 265]

    /// 地上波は系列ごとの ID（関東以外の系列局も同じ ID に寄せる）
    private static let grRules: [(keys: [String], id: Int)] = [
        (["NHK総合"], 1),
        (["Eテレ", "NHK教育"], 2),
        (["日テレ", "日本テレビ", "読売テレビ", "中京テレビ", "札幌テレビ", "福岡放送"], 4),
        (["テレビ朝日", "テレ朝", "ABCテレビ", "朝日放送", "メ～テレ", "メ〜テレ", "名古屋テレビ", "HTB", "KBC"], 5),
        (["TBS", "MBS", "毎日放送", "CBC", "HBC", "RKB"], 6),
        (["テレビ東京", "テレ東", "テレビ大阪", "テレビ愛知", "TVh", "TVQ"], 7),
        (["フジテレビ", "関西テレビ", "カンテレ", "東海テレビ", "UHB", "TNC"], 8),
        (["TOKYO MX", "MX"], 9),
        (["テレ玉", "テレビ埼玉"], 10),
        (["tvk", "テレビ神奈川"], 11),
        (["チバテレ", "千葉テレビ"], 12),
        (["サンテレビ"], 13),
        (["KBS京都"], 14),
    ]

    /// 地上波の「関東のチャンネル順」での系列の位置。NHK総合 1 → Eテレ 2 → 独立局 3 → 日テレ系 4 → テレ朝系 5
    /// → TBS 系 6 → テレ東系 7 → フジ系 8。分からない局は nil（後ろに回す）
    static func affiliationRank(name: String) -> Int? {
        let n = name.precomposedStringWithCompatibilityMapping
        guard let rule = grRules.first(where: { r in r.keys.contains { n.localizedCaseInsensitiveContains($0) } }) else { return nil }
        return rule.id >= 9 ? 3 : rule.id          // jk9〜14（MX・テレ玉・tvk・チバ・サンテレビ・KBS）は独立局
    }

    /// 実況 ID（"jk1" など）。分からなければ nil
    static func id(name: String, serviceId: Int?, type: String?) -> String? {
        if type == "BS", let sid = serviceId, bsIDs.contains(sid) { return "jk\(sid)" }
        if type == "CS", serviceId == 333 { return "jk333" }   // AT-X
        guard type == nil || type == "GR" else { return nil }
        // NFKC: 全角英数（ＮＨＫ）は半角に、半角カナは全角に揃える（.fullwidthToHalfwidth はカナまで半角にしてしまう）
        let n = name.precomposedStringWithCompatibilityMapping
        for rule in grRules where rule.keys.contains(where: { n.localizedCaseInsensitiveContains($0) }) {
            return "jk\(rule.id)"
        }
        return nil
    }
}

// MARK: - 過去ログ（録画用）

struct JikkyoClient {
    static let kakologBase = URL(string: "https://jikkyo.tsukumijima.net/api/kakolog/")!

    /// [from, to] のコメントを時刻順に。3 日を超える場合は分けて取る
    func pastComments(jkID: String, from: Date, to: Date) async throws -> [JikkyoComment] {
        var out: [JikkyoComment] = []
        var start = from
        while start < to {
            let end = min(to, start.addingTimeInterval(3 * 86400 - 60))
            var c = URLComponents(url: Self.kakologBase.appending(path: jkID), resolvingAgainstBaseURL: false)!
            c.queryItems = [
                URLQueryItem(name: "starttime", value: String(Int(start.timeIntervalSince1970))),
                URLQueryItem(name: "endtime", value: String(Int(end.timeIntervalSince1970))),
                URLQueryItem(name: "format", value: "json"),
            ]
            var req = URLRequest(url: c.url!)
            req.timeoutInterval = 30
            let (data, res) = try await Net.data(for: req, retries: 1)
            if let http = res as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
            out += Self.parse(data)
            start = end
        }
        return out.sorted { $0.time < $1.time }
    }

    /// {"packet": [{"chat": {...}}, ...]}。数字が文字列で来ることもあるので両方受ける
    static func parse(_ data: Data) -> [JikkyoComment] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packet = root["packet"] as? [[String: Any]] else { return [] }
        return packet.compactMap { item in
            guard let chat = item["chat"] as? [String: Any] else { return nil }
            return comment(from: chat)
        }
    }

    static func comment(from chat: [String: Any]) -> JikkyoComment? {
        func num(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let i = v as? Int { return Double(i) }
            if let s = v as? String { return Double(s) }
            return nil
        }
        guard let text = chat["content"] as? String, !text.isEmpty,
              !text.hasPrefix("/"),                         // 運営コメント（/nicoad など）は出さない
              let date = num(chat["date"]) else { return nil }
        let usec = num(chat["date_usec"]) ?? 0
        return JikkyoComment(time: date + usec / 1_000_000, text: text, mail: chat["mail"] as? String ?? "")
    }
}

// MARK: - ライブ（NX-Jikkyo）

/// NX-Jikkyo の視聴セッション → コメント受信セッション。届いたコメントを onComment で渡す（メインスレッド）
/// 要確認: コメント受信セッションに送る thread コマンドの形（ニコ生の旧来の形式に合わせている）
final class JikkyoLiveSession {
    private let jkID: String
    private let onComment: (JikkyoComment) -> Void
    private let onStatus: (String) -> Void
    private var watch: URLSessionWebSocketTask?
    private var comment: URLSessionWebSocketTask?
    private var keepSeat: Timer?
    private var stopped = false

    init(jkID: String, onComment: @escaping (JikkyoComment) -> Void, onStatus: @escaping (String) -> Void) {
        self.jkID = jkID
        self.onComment = onComment
        self.onStatus = onStatus
    }

    func start() {
        guard let url = URL(string: "wss://nx-jikkyo.tsukumijima.net/api/v1/channels/\(jkID)/ws/watch") else { return }
        let t = URLSession.shared.webSocketTask(with: url)
        watch = t
        t.resume()
        send(t, ["type": "startWatching", "data": ["reconnect": false]])
        receiveWatch()
        status("実況に接続中…")
    }

    func stop() {
        stopped = true
        let t = keepSeat
        DispatchQueue.main.async { t?.invalidate() }
        keepSeat?.invalidate()
        watch?.cancel(with: .goingAway, reason: nil)
        comment?.cancel(with: .goingAway, reason: nil)
    }

    private func status(_ s: String) { DispatchQueue.main.async { self.onStatus(s) } }

    private func send(_ t: URLSessionWebSocketTask, _ obj: Any) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        t.send(.string(s)) { _ in }
    }

    private func receiveWatch() {
        watch?.receive { [weak self] result in
            guard let self, !self.stopped else { return }
            switch result {
            case .failure(let e):
                self.status("実況に接続できません: \(e.localizedDescription)")
            case .success(let msg):
                if case .string(let s) = msg { self.handleWatch(s) }
                self.receiveWatch()
            }
        }
    }

    private func handleWatch(_ s: String) {
        guard let d = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let type = obj["type"] as? String else { return }
        let data = obj["data"] as? [String: Any] ?? [:]
        switch type {
        case "ping":
            if let w = watch { send(w, ["type": "pong"]) }
        case "seat":
            let sec = (data["keepIntervalSec"] as? Double) ?? 30
            DispatchQueue.main.async {
                guard !self.stopped else { return }
                self.keepSeat?.invalidate()
                self.keepSeat = Timer.scheduledTimer(withTimeInterval: sec, repeats: true) { [weak self] _ in
                    if let self, let w = self.watch { self.send(w, ["type": "keepSeat"]) }
                }
            }
        case "room":
            // NX-Jikkyo は data.messageServer.uri（ニコ生と同じ）か data.uri のどちらか
            let ms = data["messageServer"] as? [String: Any]
            guard let uri = (ms?["uri"] as? String) ?? (data["uri"] as? String), let u = URL(string: uri) else { return }
            let thread = "\(data["threadId"] ?? "")"
            connectComment(u, thread: thread, key: data["yourPostKey"] as? String)
        case "disconnect", "error":
            status("実況の接続が切れました")
        default:
            break
        }
    }

    private func connectComment(_ url: URL, thread: String, key: String?) {
        let t = URLSession.shared.webSocketTask(with: url)
        comment = t
        t.resume()
        var th: [String: Any] = ["version": "20061206", "thread": thread, "user_id": "", "res_from": -30, "with_global": 1, "scores": 1, "nicoru": 0]
        if let key { th["threadkey"] = key }
        send(t, [["ping": ["content": "rs:0"]], ["ping": ["content": "ps:0"]], ["thread": th],
                 ["ping": ["content": "pf:0"]], ["ping": ["content": "rf:0"]]])
        status("実況コメントを受信中")
        receiveComment()
    }

    private func receiveComment() {
        comment?.receive { [weak self] result in
            guard let self, !self.stopped else { return }
            switch result {
            case .failure(let e):
                self.status("実況のコメント受信が止まりました: \(e.localizedDescription)")
            case .success(let msg):
                var text: String?
                switch msg {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: break
                }
                if let text, let d = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let chat = obj["chat"] as? [String: Any], let c = JikkyoClient.comment(from: chat) {
                    DispatchQueue.main.async { if !self.stopped { self.onComment(c) } }
                }
                self.receiveComment()
            }
        }
    }
}

// MARK: - 再生位置に合わせて流す

/// 画面に流すコメントの出どころ。録画は時刻順の一覧から再生位置に合わせて出し、ライブは届いた順に出す
@MainActor
final class CommentController: ObservableObject {
    @Published private(set) var status = ""
    /// 実際に流す相手（CommentOverlay が登録する）
    var sink: ((JikkyoComment) -> Void)?
    var clear: (() -> Void)?

    private var past: [JikkyoComment] = []
    private var index = 0
    private var lastClock: Double?
    private var live: JikkyoLiveSession?
    private var loadTask: Task<Void, Never>?
    /// ライブで届いたコメント（直近 40 分）。追っかけ再生のとき、見ている時刻に合わせて出し直すため
    private var history: [JikkyoComment] = []
    /// 追っかけ再生中: ライブのコメントは画面に流さず history に貯め、tick で見ている時刻の分を出す
    private var replaying = false

    private func receiveLive(_ c: JikkyoComment) {
        history.append(c)
        // 45 分を超えたら 40 分まで減らす（毎回は減らさない）。減らした分だけ再生位置もずらす
        if history.count > 30_000 || (history.first.map { c.time - $0.time > 45 * 60 } ?? false) {
            let cut = c.time - 40 * 60
            var k = history.firstIndex { $0.time >= cut } ?? history.count
            k = max(k, history.count - 25_000)
            if k > 0 {
                history.removeFirst(k)
                index = max(0, index - k)
            }
        }
        if !replaying { sink?(c) }
    }

    /// 追っかけ再生に入った / ライブに戻った
    func setReplaying(_ on: Bool) {
        guard on != replaying else { return }
        replaying = on
        lastClock = nil
        clear?()
    }

    /// 追っかけ再生中に呼ぶ: いま見ている放送時刻（UNIX 秒）。ライブで貯めたコメントから、その時刻の分を出す
    func tickReplay(broadcastTime t: Double) {
        guard replaying, !history.isEmpty else { return }
        if let last = lastClock, t < last - 0.5 || t > last + 2 {
            index = history.firstIndex { $0.time >= t } ?? history.count
            clear?()
        } else if lastClock == nil {
            index = history.firstIndex { $0.time >= t - 0.5 } ?? history.count
        }
        lastClock = t
        var shown = 0
        while index < history.count, history[index].time <= t {
            if shown < 20 { sink?(history[index]) }
            shown += 1
            index += 1
        }
    }

    // 録画: 放送時刻 [from, to] の過去ログを読む
    func loadPast(jkID: String?, from: Date, to: Date) {
        stopLive()
        loadTask?.cancel()
        past = []; index = 0; lastClock = nil
        guard let jkID else { status = "この局は実況がありません"; return }
        status = "実況の過去ログを読み込み中…"
        loadTask = Task {
            do {
                let list = try await JikkyoClient().pastComments(jkID: jkID, from: from.addingTimeInterval(-60), to: to.addingTimeInterval(60))
                guard !Task.isCancelled else { return }
                past = list
                status = list.isEmpty ? "実況の過去ログはありません（放送直後は数分遅れて入ります）" : "実況 \(list.count) 件"
            } catch {
                status = "実況の過去ログを取れませんでした"
            }
        }
    }

    /// 録画の再生中に呼ぶ: いまの放送時刻（UNIX 秒）。シークしたら（2 秒以上飛んだら）その位置から出し直す
    func tick(broadcastTime t: Double) {
        guard !past.isEmpty else { return }
        if let last = lastClock, t < last - 0.5 || t > last + 2 {
            index = past.firstIndex { $0.time >= t } ?? past.count
            clear?()
        } else if lastClock == nil {
            index = past.firstIndex { $0.time >= t - 0.5 } ?? past.count
        }
        lastClock = t
        var shown = 0
        while index < past.count, past[index].time <= t {
            if shown < 20 { sink?(past[index]) }       // 一度に出しすぎない（盛り上がった瞬間の取りこぼしは許す）
            shown += 1
            index += 1
        }
    }

    // ライブ
    func startLive(jkID: String?) {
        loadTask?.cancel()
        past = []
        stopLive()
        guard let jkID else { status = "この局は実況がありません"; return }
        history = []
        let s = JikkyoLiveSession(jkID: jkID,
                                  onComment: { [weak self] c in self?.receiveLive(c) },
                                  onStatus: { [weak self] st in self?.status = st })
        live = s
        s.start()
    }

    func stopLive() {
        live?.stop()
        live = nil
    }

    func stopAll() {
        stopLive()
        loadTask?.cancel()
        past = []
        history = []
        replaying = false
        clear?()
        status = ""
    }
}
