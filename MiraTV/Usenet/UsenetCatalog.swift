import Foundation

// nzb-dl のテレビのアーカイブ（約 7.6 万件）の一覧を端末に持ち、端末の中で探す。
//
// nzb-dl には検索の API が無い（アップロード順のページ送りだけ）ので、全件を一度取って保存し、
// 次からは新しい分だけを取り足す。起動直後は保存分をすぐ出す（「接続中…」で待たせない）。
// サーバーの件数と合わなくなったとき（有効/無効が切り替わった等）だけ全件を取り直す。

/// アーカイブの 1 番組（再投稿 [reupload-N] はまとめて 1 件にする）
struct UsenetEntry: Identifiable, Hashable {
    /// 再生に使う item の id
    let id: String
    /// NZB のファイル名（.nzb 付き）
    let name: String
    let bytes: Int64
    /// 放送開始（名前の先頭の日時、JST）。名前が形式に合わなければ nil
    let airDate: Date?
    /// 局名（名前のまま。全角のことが多い）
    let station: String
    /// 番組名（[字][デ] などの記号と [reupload-N] を除いたもの）
    let title: String
    /// [字] [デ] [生] [再] など
    let flags: [String]
    /// 同じ放送の再投稿（本命が読めなかったときの予備。再投稿番号の小さい順）
    let alternates: [NzbItemRaw]
    /// 検索用（全角→半角、ひらがな→カタカナ、小文字）
    let searchKey: String
    /// シリーズ名（表示用）と、まとめるためのキー（SeriesKey）
    let seriesTitle: String
    let seriesKey: String

    var watchKey: String { "nzb-\(id)" }
    /// 本命の item
    var primary: NzbItemRaw { NzbItemRaw(id: id, name: name, bytes: bytes, created: 0) }
}

/// 同じ番組の別の回をまとめたもの（2 回以上あるものだけ）
struct UsenetSeries: Identifiable, Hashable {
    let key: String
    let title: String
    /// いちばん多く出てくる局
    let station: String
    /// 出てくる局の数
    let stationCount: Int
    let count: Int
    let first: Date?
    let latest: Date?
    var id: String { key }
}

struct StationCount: Hashable, Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

@MainActor
final class UsenetCatalog: ObservableObject {
    static let shared = UsenetCatalog()

    /// 放送日時の新しい順
    @Published private(set) var entries: [UsenetEntry] = []
    /// 局ごとの件数（多い順）
    @Published private(set) var stations: [StationCount] = []
    /// シリーズ（最新の回が新しい順）
    @Published private(set) var series: [UsenetSeries] = []
    /// シリーズのキー → その回（放送の古い順）
    private(set) var seriesMembers: [String: [UsenetEntry]] = [:]
    @Published private(set) var syncing = false
    /// 取得中の件数（done / サーバーの総数）
    @Published private(set) var progressDone = 0
    @Published private(set) var progressTotal: Int?
    @Published private(set) var error: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var serverTotal: Int?
    /// 一覧を作り直すたびに増える（画面の絞り込みをやり直す合図）
    @Published private(set) var revision = 0

    /// サーバーの生の一覧（アップロードの新しい順）
    private var raw: [NzbItemRaw] = []
    /// 初回の全件取得が途中で終わっている（次はその続きから取る）
    private var partial = false
    private var loadTask: Task<Void, Never>?
    /// 取得は画面ではなくここが持つ（タブを切り替えて画面の task が止まっても、最後まで続ける）
    private var syncTask: Task<Void, Never>?
    private var rebuildGeneration = 0

    private init() {}

    // MARK: - 端末の保存

    private struct Stored: Codable {
        var raw: [NzbItemRaw]
        var lastSync: Double?
        var total: Int?
        var partial: Bool?
    }

    /// Caches は 10 日で消す仕組み（DiskCache.prune）があるので、Application Support に置く
    private nonisolated static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("MiraTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("usenet-catalog.json")
    }

    /// 保存分を読み込む（初回だけ）。同時に呼ばれても読み込みは 1 回で、全員が読み終わりを待つ
    func loadIfNeeded() async {
        if let t = loadTask { await t.value; return }
        let t = Task { await self.loadFromDisk() }
        loadTask = t
        await t.value
    }

    private func loadFromDisk() async {
        let stored: Stored? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: Self.fileURL) else { return nil }
            return try? JSONDecoder().decode(Stored.self, from: data)
        }.value
        guard let stored, raw.isEmpty else { return }
        raw = stored.raw
        partial = stored.partial ?? false
        lastSync = stored.lastSync.map { Date(timeIntervalSince1970: $0) }
        serverTotal = stored.total
        await rebuild()
        DebugLog.log("nzb", "保存分の一覧 \(raw.count) 件 → \(entries.count) 番組\(partial ? "（初回の取得の途中）" : "")")
    }

    private func save() {
        let stored = Stored(raw: raw, lastSync: lastSync?.timeIntervalSince1970, total: serverTotal, partial: partial)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(stored) else { return }
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    // MARK: - 取得

    /// 新しい分を取り足す。full = true か保存分が無いときは全件を取り直す。
    /// 取得中にもう一度呼ばれたら、新しく始めずに今の取得の終わりを待つ
    func refresh(full: Bool = false) async {
        if let t = syncTask { await t.value; return }
        guard let client = Servers.nzbdl else {
            error = "nzb-dl の URL と API キーを設定してください（設定タブ）"
            return
        }
        // 呼んだ側（画面の task）が止められても、この Task は止まらない
        let t = Task {
            await self.runRefresh(client: client, full: full)
            self.syncTask = nil
        }
        syncTask = t
        await t.value
    }

    private func runRefresh(client: NzbDlClient, full: Bool) async {
        await loadIfNeeded()
        syncing = true
        defer { syncing = false; progressTotal = nil }
        error = nil
        if full || raw.isEmpty {
            _ = await sync(client: client, mode: .full)
            return
        }
        // 初回の全件取得が途中で終わっていたら、まずその続き（古い側）を取る
        if partial {
            guard await sync(client: client, mode: .resume) != nil else { return }
        }
        // 新しい側の差分。件数がサーバーと合わなければ（有効/無効の切り替え等）全件を取り直す
        if await sync(client: client, mode: .incremental) == true {
            DebugLog.log("nzb", "件数がサーバーと合わない（端末 \(raw.count) / サーバー \(serverTotal ?? -1)）→ 全件取り直し")
            _ = await sync(client: client, mode: .full)
        }
    }

    private enum SyncMode: String {
        /// 先頭から全部
        case full
        /// 保存済みの件数の位置から、残り（古い側）を全部
        case resume
        /// 先頭から、保存済みの件に届くまで
        case incremental
    }

    /// 1 回分の取得。失敗なら nil、件数がサーバーと合わなければ true
    private func sync(client: NzbDlClient, mode: SyncMode) async -> Bool? {
        let known = Set(raw.map(\.id))
        var fetched: [NzbItemRaw] = mode == .resume ? raw : []
        var seen: Set<String> = mode == .resume ? known : []
        // 続きは保存済みの件数の位置から。上に新しい投稿が増えていると少し重なるが、seen で弾くので取りこぼさない
        var offset = mode == .resume ? raw.count : 0
        var total: Int?
        var nextPublish = 2_000
        // 差分は小さいページから（サーバーは 1000 件で 10〜20 秒かかる。新しい分は普通は数十件）。届かなければ広げる
        var pageSize = mode == .incremental ? 50 : 1_000
        progressDone = offset
        progressTotal = serverTotal
        let started = Date()
        do {
            while true {
                let page = try await client.items(limit: pageSize, offset: offset)
                if mode == .incremental { pageSize = min(pageSize * 4, 1_000) }
                if let t = page.total { total = t; progressTotal = t }
                if page.items.isEmpty { break }
                var hitKnown = false
                for it in page.items {
                    if known.contains(it.id) { hitKnown = true }
                    if seen.insert(it.id).inserted { fetched.append(it) }
                }
                offset += page.items.count
                progressDone = offset
                // 差分: 保存済みの件に届いたら、それより古い分は持っている
                if mode == .incremental && hitKnown { break }
                if let total, offset >= total { break }
                // 初回の全件取得は時間がかかるので、途中でも見えるようにし、端末にも残す（アプリを閉じても続きから）
                if mode != .incremental && (raw.isEmpty || partial) && fetched.count >= nextPublish {
                    nextPublish = fetched.count < 20_000 ? 20_000 : fetched.count + 25_000
                    raw = fetched
                    partial = true
                    await rebuild()
                    save()
                }
            }
        } catch {
            self.error = describeError(error)
            DebugLog.log("nzb", "一覧の取得に失敗（\(mode.rawValue)）offset=\(offset): \(describeError(error))")
            // 初回の取得なら、取れた分を使えるようにして次は続きから
            if mode != .incremental && (raw.isEmpty || partial) && !fetched.isEmpty {
                raw = fetched
                partial = true
                await rebuild()
                save()
            }
            return nil
        }

        switch mode {
        case .full, .resume:
            raw = fetched
            partial = false
        case .incremental:
            raw = fetched.filter { !known.contains($0.id) } + raw
        }
        serverTotal = total
        lastSync = Date()
        await rebuild()
        save()
        DebugLog.log("nzb", "一覧を取得（\(mode.rawValue)）\(fetched.count) 件 \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒 → 計 \(raw.count) 件")
        // 無効にした・消した数件のずれで全件（約 47 万件・1 時間以上）を取り直さない。大きくずれたときだけ
        if let total, abs(raw.count - total) > max(200, total / 500) { return true }
        return false
    }

    /// 生の一覧から、番組の一覧と局の件数を作り直す（重いので裏で）
    private func rebuild() async {
        rebuildGeneration += 1
        let gen = rebuildGeneration
        let snapshot = raw
        let result = await Task.detached(priority: .userInitiated) { Self.build(snapshot) }.value
        guard gen == rebuildGeneration else { return }
        entries = result.entries
        stations = result.stations
        series = result.series
        seriesMembers = result.members
        revision += 1
    }

    // MARK: - 本体ファイルの種類（lookup の結果を覚える）

    private static let extKey = "nzbMainExt.v1"

    /// 本体ファイルの拡張子（ts / mp4 / 7z …）。まだ調べていなければ nil
    /// 一覧用: 1 回の読み出しで全部（行ごとに読み直すと重い）
    func extSnapshot() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.extKey) as? [String: String] ?? [:]
    }

    func mainExt(_ id: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: Self.extKey) as? [String: String])?[id]
    }

    func setMainExt(_ ext: String, for id: String) {
        var d = UserDefaults.standard.dictionary(forKey: Self.extKey) as? [String: String] ?? [:]
        d[id] = ext
        if d.count > 3_000 { d = Dictionary(uniqueKeysWithValues: d.suffix(2_000).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(d, forKey: Self.extKey)
    }

    // MARK: - シリーズ

    /// 同じシリーズの次の回（放送日時が後のもののうち一番近いもの）。無ければ nil
    func nextInSeries(_ e: UsenetEntry) -> UsenetEntry? {
        guard let list = seriesMembers[e.seriesKey], let i = list.firstIndex(where: { $0.id == e.id }) else { return nil }
        return list[(i + 1)...].first { $0.airDate != e.airDate }
    }

    func members(of key: String) -> [UsenetEntry] { seriesMembers[key] ?? [] }

    // MARK: - 探す

    /// 局と文字で絞る。文字は空白で区切ると全部を含むもの（全角/半角・ひらがな/カタカナは区別しない）。
    /// 7 万件を舐めるので、画面からは裏のスレッドで呼ぶ
    nonisolated static func filter(_ entries: [UsenetEntry], query: String, station: String?) -> [UsenetEntry] {
        let tokens = normalize(query).split(whereSeparator: { $0 == " " }).map(String.init)
        if tokens.isEmpty && station == nil { return entries }
        return entries.filter { e in
            if let station, e.station != station { return false }
            return tokens.allSatisfy { e.searchKey.contains($0) }
        }
    }

    /// シリーズを局と文字で絞る（シリーズ名と局で探す）
    nonisolated static func filterSeries(_ list: [UsenetSeries], query: String, station: String?,
                                         members: [String: [UsenetEntry]]) -> [UsenetSeries] {
        let tokens = normalize(query).split(whereSeparator: { $0 == " " }).map(String.init)
        if tokens.isEmpty && station == nil { return list }
        return list.filter { s in
            if let station, s.station != station,
               !(members[s.key]?.contains { $0.station == station } ?? false) { return false }
            if tokens.isEmpty { return true }
            let hay = s.key + " " + normalize(s.station)
            return tokens.allSatisfy { hay.contains($0) }
        }
    }

    // MARK: - 名前の解釈（裏のスレッドで呼ぶ）

    private struct Parsed {
        let raw: NzbItemRaw
        let airDate: Date?
        let station: String
        let title: String
        let flags: [String]
        let reupload: Int
    }

    private struct Built {
        let entries: [UsenetEntry]
        let stations: [StationCount]
        let series: [UsenetSeries]
        let members: [String: [UsenetEntry]]
    }

    private nonisolated static func build(_ items: [NzbItemRaw]) -> Built {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "Asia/Tokyo")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = TimeZone(identifier: "Asia/Tokyo")
        dayFmt.dateFormat = "yyyyMMdd M/d"

        // 同じ放送（日時・局・番組名）の再投稿をまとめる。本命は再投稿番号の小さいもの
        var groups: [String: [Parsed]] = [:]
        var order: [String] = []
        for it in items {
            if it.category == "radio" { continue }   // ラジオは radio-web 側で扱う（TV のアーカイブ一覧には出さない）
            let p = parse(it, fmt: fmt)
            let key = p.airDate.map { "\(Int($0.timeIntervalSince1970))|\(normalize(p.station))|\(normalize(p.title))" } ?? "name|\(it.id)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(p)
        }

        var entries: [UsenetEntry] = []
        entries.reserveCapacity(order.count)
        var counts: [String: Int] = [:]
        for key in order {
            guard let g = groups[key] else { continue }
            let sorted = g.sorted { $0.reupload < $1.reupload }
            let p = sorted[0]
            let day = p.airDate.map { dayFmt.string(from: $0) } ?? ""
            let series = SeriesKey.make(title: p.title)
            entries.append(UsenetEntry(
                id: p.raw.id, name: p.raw.name, bytes: p.raw.bytes, airDate: p.airDate,
                station: p.station, title: p.title, flags: p.flags,
                alternates: sorted.dropFirst().map(\.raw),
                searchKey: normalize("\(p.station) \(p.title) \(day)"),
                seriesTitle: series.display, seriesKey: series.key))
            if !p.station.isEmpty { counts[p.station, default: 0] += 1 }
        }
        // 放送日時の新しい順（日時が読めないものは最後に、アップロード順のまま）
        entries.sort { a, b in
            switch (a.airDate, b.airDate) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            default: return false
            }
        }
        let stations = counts.map { StationCount(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }

        // シリーズ: 放送の古い順に並べた回の一覧（entries は新しい順なので逆から積む）
        var members: [String: [UsenetEntry]] = [:]
        for e in entries.reversed() where e.airDate != nil && !e.seriesKey.isEmpty {
            members[e.seriesKey, default: []].append(e)
        }
        members = members.filter { $0.value.count >= 2 }
        var series: [UsenetSeries] = []
        series.reserveCapacity(members.count)
        for (key, list) in members {
            var st: [String: Int] = [:]
            for e in list where !e.station.isEmpty { st[e.station, default: 0] += 1 }
            let top = st.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? ""
            // 表示名は最新の回のもの（局の付け方が途中で変わっても、今の名前で出す）
            series.append(UsenetSeries(key: key, title: list.last?.seriesTitle ?? key, station: top,
                                       stationCount: st.count, count: list.count,
                                       first: list.first?.airDate, latest: list.last?.airDate))
        }
        series.sort { ($0.latest ?? .distantPast) > ($1.latest ?? .distantPast) }
        return Built(entries: entries, stations: stations, series: series, members: members)
    }

    /// `YYYYMMDD-HHMMSS <局> <番組名>[字][デ]… [reupload-N].nzb`
    private nonisolated static func parse(_ it: NzbItemRaw, fmt: DateFormatter) -> Parsed {
        var base = it.name
        if base.lowercased().hasSuffix(".nzb") { base = String(base.dropLast(4)) }

        // [reupload-N]
        var reupload = 0
        if let r = base.range(of: "[reupload-") {
            let after = base[r.upperBound...]
            if let close = after.firstIndex(of: "]") {
                reupload = Int(after[..<close]) ?? 1
                base.removeSubrange(r.lowerBound...close)
            } else {
                reupload = 1
                base.removeSubrange(r.lowerBound...)
            }
        }

        // 先頭の日時
        var airDate: Date?
        var rest = Substring(base)
        let chars = Array(base.prefix(15))
        if chars.count == 15, chars[8] == "-",
           chars.enumerated().allSatisfy({ $0.offset == 8 || $0.element.isASCII && $0.element.isNumber }) {
            airDate = fmt.date(from: String(chars))
            rest = base.dropFirst(15)
        }
        rest = rest.drop(while: { $0 == " " || $0 == "\u{3000}" })

        // 局（次の空白まで）と番組名
        var station = ""
        var title = String(rest)
        if airDate != nil, let sp = rest.firstIndex(where: { $0 == " " || $0 == "\u{3000}" }) {
            station = String(rest[..<sp])
            title = String(rest[sp...]).trimmingCharacters(in: .whitespaces)
        }

        // [字] [デ] [生] など、3 文字までの角括弧の記号を抜き出す
        var flags: [String] = []
        var cleaned = ""
        var i = title.startIndex
        while i < title.endIndex {
            if title[i] == "[", let close = title[i...].firstIndex(of: "]") {
                let inner = title[title.index(after: i)..<close]
                if !inner.isEmpty && inner.count <= 3 {
                    flags.append(String(inner))
                    i = title.index(after: close)
                    continue
                }
            }
            cleaned.append(title[i])
            i = title.index(after: i)
        }
        title = cleaned.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { title = String(rest) }
        return Parsed(raw: it, airDate: airDate, station: station, title: title, flags: flags, reupload: reupload)
    }

    /// 検索用の正規化: 全角英数記号→半角、全角空白→空白、ひらがな→カタカナ、英字は小文字
    /// （ICU の applyingTransform は 7 万件だと遅いので、文字ごとに自前で変換する）
    nonisolated static func normalize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            var v = u.value
            if v == 0x3000 { v = 0x20 }
            else if (0xFF01...0xFF5E).contains(v) { v -= 0xFEE0 }
            else if (0x3041...0x3096).contains(v) { v += 0x60 }
            if (0x41...0x5A).contains(v) { v += 0x20 }
            if let n = Unicode.Scalar(v) { out.append(n) }
        }
        return String(out)
    }
}

/// 最後まで見た回（シリーズの一覧で「見た」を出し、次に見る回を決めるため）。
/// 続きの位置（WatchPositions）は見終わると消えるので、別に持つ
enum UsenetWatched {
    private static let key = "nzbWatched.v1"

    static var snapshot: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func mark(_ id: String) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !list.contains(id) else { return }
        list.append(id)
        if list.count > 5_000 { list.removeFirst(list.count - 4_000) }    // 古いものから忘れる
        UserDefaults.standard.set(list, forKey: key)
    }

    static func unmark(_ id: String) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == id }
        UserDefaults.standard.set(list, forKey: key)
    }
}
