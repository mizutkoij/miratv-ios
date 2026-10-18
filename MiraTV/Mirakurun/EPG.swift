import Foundation

// MARK: - Mirakurun の番組（EPGStation が使えないときの代替）

/// Mirakurun `/api/programs?networkId=&serviceId=` の 1 要素（実測: 1 局 約 450 件・0.5MB・約 7 日分）。
/// 時刻は ms の epoch、duration も ms。
struct MirakurunProgram: Decodable, Identifiable, Hashable {
    let id: Int64
    let name: String?
    let description: String?
    let startAt: Int64
    let duration: Int64
    let extended: [String: String]
    /// ISDB のコンポーネント種別 0x02 = デュアルモノ（主/副音声）
    let audioComponentTypes: [Int]
    let genreLv1: [Int]

    enum CodingKeys: String, CodingKey { case id, name, description, startAt, duration, extended, audios, genres }
    private struct Audio: Decodable { let componentType: Int? }
    private struct Genre: Decodable { let lv1: Int? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        startAt = try c.decode(Int64.self, forKey: .startAt)
        duration = (try? c.decode(Int64.self, forKey: .duration)) ?? 0
        extended = (try? c.decode([String: String].self, forKey: .extended)) ?? [:]
        let audios = (try? c.decode([LossyDecodable<Audio>].self, forKey: .audios)) ?? []
        audioComponentTypes = audios.compactMap { $0.value?.componentType }
        let genres = (try? c.decode([LossyDecodable<Genre>].self, forKey: .genres)) ?? []
        genreLv1 = genres.compactMap { $0.value?.lv1 }
    }
}

// MARK: - 画面で使う番組（EPGStation / Mirakurun どちらから来ても同じ形）

struct Program: Identifiable, Hashable {
    let id: Int64
    /// EPGStation の channelId。Mirakurun のサービス ID（networkId*100000+serviceId）と一致する
    let channelId: Int
    let start: Date
    let end: Date
    let name: String
    let description: String
    let extended: String
    let genreLv1: [Int]
    let isFree: Bool
    let isDualMono: Bool

    init(es p: ESProgram) {
        id = p.id
        channelId = p.channelId
        start = Date(timeIntervalSince1970: Double(p.startAt) / 1000)
        end = Date(timeIntervalSince1970: Double(p.endAt) / 1000)
        name = p.name ?? ""
        description = p.description ?? ""
        extended = p.extended ?? ""
        genreLv1 = [p.genre1, p.genre2, p.genre3].compactMap { $0 }
        isFree = p.isFree ?? true
        isDualMono = p.audioComponentType == 0x02
    }

    init(mirakurun p: MirakurunProgram, channelId: Int) {
        id = p.id
        self.channelId = channelId
        start = Date(timeIntervalSince1970: Double(p.startAt) / 1000)
        end = Date(timeIntervalSince1970: Double(p.startAt + p.duration) / 1000)
        name = p.name ?? ""
        description = p.description ?? ""
        extended = ["番組内容", "出演者", "番組詳細"].compactMap { k in p.extended[k].map { "【\(k)】\($0)" } }.joined(separator: "\n")
        genreLv1 = p.genreLv1
        isFree = true
        isDualMono = p.audioComponentTypes.contains(0x02)
    }

    var title: String { name.isEmpty ? "（番組情報なし）" : name }
    var timeRange: String { "\(start.hm)–\(end.hm)" }
    var durationMinutes: Double { end.timeIntervalSince(start) / 60 }

    func progress(at now: Date) -> Double {
        let d = end.timeIntervalSince(start)
        return d > 0 ? min(max(now.timeIntervalSince(start) / d, 0), 1) : 0
    }

    func isOnAir(at now: Date) -> Bool { start <= now && now < end }

    /// 概要 + 拡張テキスト（番組内容・出演者など）
    var detailText: String {
        [description, extended].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 名前の末尾の [字][デ][多] などの記号
    var marks: [String] {
        let re = try? NSRegularExpression(pattern: "\\[(.)\\]")
        let ns = name as NSString
        return (re?.matches(in: name, range: NSRange(location: 0, length: ns.length)) ?? [])
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    /// ARIB のジャンル大分類（lv1）
    var genreNames: [String] {
        let table = [0: "ニュース・報道", 1: "スポーツ", 2: "情報・ワイドショー", 3: "ドラマ", 4: "音楽",
                     5: "バラエティ", 6: "映画", 7: "アニメ・特撮", 8: "ドキュメンタリー・教養", 9: "劇場・公演",
                     10: "趣味・教育", 11: "福祉", 15: "その他"]
        var seen = Set<Int>()
        return genreLv1.filter { seen.insert($0).inserted }.compactMap { table[$0] }
    }
}

// MARK: - 取得数の制限

/// 同時に走らせる取得数を絞る（Mirakurun は 1 局 0.5MB あるため、一覧で一気に要求しない）
actor FetchLimiter {
    private var running = 0
    private let limit: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }
}

// MARK: - 番組情報の保管場所

/// 局ごとの番組情報キャッシュ。一覧・再生画面・ほかのチャンネルが共有する。
///
/// - 概要（overview）: EPGStation の `/api/schedules` で全局の「いま〜2 時間」を 1 回で取る（約 560KB・0.5 秒）。
///   これに載った局が「実際に見られる局」で、放送していない副チャンネルやワンセグは載らない。
/// - 詳細（detail）: 再生中の局だけ、EPGStation（無ければ Mirakurun）から 1 日分を取る
@MainActor
final class EPGStore: ObservableObject {
    @Published private(set) var overview: [Int: [Program]] = [:]
    @Published private(set) var detail: [Int: [Program]] = [:]
    /// EPGStation の概要に載った局。nil = まだ分からない（取得前・EPGStation 未使用）
    @Published private(set) var activeChannelIDs: Set<Int>?
    @Published private(set) var overviewError: String?
    /// 概要が取れなかった（EPGStation 未設定・接続不可）。このときだけ、局ごとに Mirakurun から取る
    @Published private(set) var overviewFailed = false
    /// 局 ID → 局情報（予約・録画の一覧で局名を出すために使う）
    @Published private(set) var channelInfo: [Int: ESChannel] = [:]

    private var overviewAt: Date?
    private var inflight: Set<Int> = []
    private var fetchedAt: [Int: Date] = [:]
    private var retryAfter: [Int: TimeInterval] = [:]
    private let limiter = FetchLimiter(3)

    private static let overviewCacheKey = "es-overview"
    private var restored = false
    /// 概要を最後に取れた時刻（端末から戻した分は保存した時刻）。2 時間より古いと、もう放送中の番組を持っていない
    private var overviewGoodAt: Date?
    private var overviewIsStale: Bool {
        guard let at = overviewGoodAt, !overview.isEmpty else { return true }
        return Date().timeIntervalSince(at) > 2 * 3600
    }

    /// 前回の概要（局の顔ぶれ・番組名）を端末から戻す。起動直後に「接続中」で待たせず、局一覧を確定させるため。
    /// 放送中の判定は時刻で行うので、古い番組は自然に表示から外れる
    func restoreFromDisk() {
        guard !restored else { return }
        restored = true
        guard overview.isEmpty, let list = EPGStationClient.cachedSchedules(key: Self.overviewCacheKey), !list.isEmpty else { return }
        apply(list)
        overviewGoodAt = Date().addingTimeInterval(-(DiskCache.age(Self.overviewCacheKey) ?? 365 * 86400))
    }

    private func apply(_ list: [ESSchedule]) {
        var map: [Int: [Program]] = [:]
        var info: [Int: ESChannel] = [:]
        for s in list {
            map[s.channel.id] = s.programs.map(Program.init(es:)).sorted { $0.start < $1.start }
            info[s.channel.id] = s.channel
        }
        overview = map
        channelInfo = info
        activeChannelIDs = Set(map.keys)
    }

    /// 全局の概要。10 分ごとに取り直しても重くない大きさだが、一覧の表示のたびには叩かない
    func refreshOverview(es: EPGStationClient?, force: Bool = false) async {
        restoreFromDisk()
        guard let es else { overviewFailed = overviewIsStale; return }
        if !force, let at = overviewAt, Date().timeIntervalSince(at) < 60 { return }
        overviewAt = Date()
        do {
            let now = Date()
            let list = try await es.schedules(from: now, to: now.addingTimeInterval(2 * 3600),
                                              cacheKey: Self.overviewCacheKey)
            apply(list)
            overviewGoodAt = Date()
            overviewError = nil
            overviewFailed = false
        } catch {
            overviewAt = nil
            overviewError = describeError(error)
            // 前回の概要がまだ使える（2 時間以内）なら、それで続ける。局ごとに Mirakurun から 0.5MB ずつ取り直す
            // フォールバック（重い）は、使える概要を何も持っていないときだけ
            overviewFailed = overviewIsStale
        }
    }

    /// 再生画面用: その局の 1 日分
    func loadDetail(service: MirakurunService, es: EPGStationClient?, mirakurun: MirakurunClient?) async {
        let key = service.id
        if inflight.contains(key) { return }
        if let at = fetchedAt[key], Date().timeIntervalSince(at) < (retryAfter[key] ?? 600) { return }
        inflight.insert(key)
        defer { inflight.remove(key) }

        if let es, activeChannelIDs?.contains(key) ?? true {
            do {
                if let s = try await es.schedule(channelId: key, from: Date(), days: 1) {
                    detail[key] = s.programs.map(Program.init(es:)).sorted { $0.start < $1.start }
                    fetchedAt[key] = Date(); retryAfter[key] = 600
                    return
                }
            } catch { /* Mirakurun にフォールバック */ }
        }
        guard let mirakurun else { return }
        await limiter.acquire()
        do {
            let list = try await mirakurun.programs(for: service)
            await limiter.release()
            detail[key] = list.map { Program(mirakurun: $0, channelId: key) }
            retryAfter[key] = 600
        } catch {
            await limiter.release()
            retryAfter[key] = 60
        }
        fetchedAt[key] = Date()
    }

    /// EPGStation が使えない（概要が取れない）ときの一覧用: 局ごとに Mirakurun から取る
    func loadViaMirakurun(_ service: MirakurunService, client: MirakurunClient) async {
        await loadDetail(service: service, es: nil, mirakurun: client)
    }

    private func programs(for service: MirakurunService) -> [Program] {
        if let d = detail[service.id], !d.isEmpty { return d }
        return overview[service.id] ?? []
    }

    func current(_ service: MirakurunService, at now: Date) -> Program? {
        if let p = detail[service.id]?.first(where: { $0.isOnAir(at: now) }) { return p }
        return overview[service.id]?.first { $0.isOnAir(at: now) }
    }

    /// いま放送中より後の番組
    func upcoming(_ service: MirakurunService, at now: Date, limit: Int) -> [Program] {
        let list = programs(for: service).filter { $0.start >= now }
        if list.count >= limit || detail[service.id] == nil { return Array(list.prefix(limit)) }
        return Array(list.prefix(limit))
    }

    /// 一覧に出す局か: EPGStation の概要が取れていればそれに載った局だけ。取れていなければ全部
    func isActive(_ service: MirakurunService) -> Bool {
        activeChannelIDs?.contains(service.id) ?? true
    }
}
