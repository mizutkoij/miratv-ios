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

    var watchKey: String { "nzb-\(id)" }
    /// 本命の item
    var primary: NzbItemRaw { NzbItemRaw(id: id, name: name, bytes: bytes, created: 0) }
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
    private var loadedFromDisk = false
    private var rebuildGeneration = 0

    private init() {}

    // MARK: - 端末の保存

    private struct Stored: Codable {
        var raw: [NzbItemRaw]
        var lastSync: Double?
        var total: Int?
    }

    /// Caches は 10 日で消す仕組み（DiskCache.prune）があるので、Application Support に置く
    private nonisolated static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("MiraTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("usenet-catalog.json")
    }

    /// 保存分を読み込む（初回だけ）。一覧の画面を開いたときに呼ぶ
    func loadIfNeeded() async {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        let stored: Stored? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: Self.fileURL) else { return nil }
            return try? JSONDecoder().decode(Stored.self, from: data)
        }.value
        guard let stored, raw.isEmpty else { return }
        raw = stored.raw
        lastSync = stored.lastSync.map { Date(timeIntervalSince1970: $0) }
        serverTotal = stored.total
        await rebuild()
        DebugLog.log("nzb", "保存分の一覧 \(raw.count) 件 → \(entries.count) 番組")
    }

    private func save() {
        let stored = Stored(raw: raw, lastSync: lastSync?.timeIntervalSince1970, total: serverTotal)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(stored) else { return }
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    // MARK: - 取得

    /// 新しい分を取り足す。full = true か保存分が無いときは全件を取り直す
    func refresh(full: Bool = false) async {
        guard !syncing else { return }
        guard let client = Servers.nzbdl else {
            error = "nzb-dl の URL と API キーを設定してください（設定タブ）"
            return
        }
        await loadIfNeeded()
        syncing = true
        defer { syncing = false; progressTotal = nil }
        error = nil
        var needFull = full || raw.isEmpty
        // 取り足しで件数が合わなかったら、もう 1 回だけ全件で取り直す
        for _ in 0..<2 {
            let mismatch = await sync(client: client, full: needFull)
            if !mismatch || needFull { break }
            DebugLog.log("nzb", "件数がサーバーと合わない（端末 \(raw.count) / サーバー \(serverTotal ?? -1)）→ 全件取り直し")
            needFull = true
        }
    }

    /// 1 回分の取得。件数がサーバーと合わなければ true
    private func sync(client: NzbDlClient, full: Bool) async -> Bool {
        let known = Set(raw.map(\.id))
        var fetched: [NzbItemRaw] = []
        var seen = Set<String>()
        var offset = 0
        var total: Int?
        var nextPublish = 2_000
        let pageSize = 1_000
        progressDone = 0
        progressTotal = serverTotal
        let started = Date()
        do {
            while true {
                try Task.checkCancellation()
                let page = try await client.items(limit: pageSize, offset: offset)
                if let t = page.total { total = t; progressTotal = t }
                if page.items.isEmpty { break }
                var hitKnown = false
                for it in page.items where seen.insert(it.id).inserted {
                    fetched.append(it)
                    if known.contains(it.id) { hitKnown = true }
                }
                offset += page.items.count
                progressDone = offset
                // 取り足し: 保存済みの件に届いたら、それより古い分は持っている
                if !full && hitKnown { break }
                if let total, offset >= total { break }
                // 初回の全件取得は時間がかかるので、途中でも見えるようにする
                if full && raw.isEmpty && fetched.count >= nextPublish {
                    nextPublish = fetched.count < 20_000 ? 20_000 : fetched.count + 25_000
                    raw = fetched
                    await rebuild()
                    raw = []          // 取得が終わるまでは「保存分なし」のまま扱う
                }
            }
        } catch {
            if !(error is CancellationError) { self.error = describeError(error) }
            DebugLog.log("nzb", "一覧の取得に失敗 offset=\(offset): \(describeError(error))")
            // 初回で途中まで取れていれば、その分は使えるようにしておく（次の更新で続きを取る）
            if full && raw.isEmpty && !fetched.isEmpty {
                raw = fetched
                await rebuild()
                save()
            }
            return false
        }

        if full {
            raw = fetched
        } else {
            raw = fetched.filter { !known.contains($0.id) } + raw
        }
        serverTotal = total
        lastSync = Date()
        await rebuild()
        save()
        DebugLog.log("nzb", "一覧を\(full ? "全件" : "差分")取得 \(fetched.count) 件 \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒 → 計 \(raw.count) 件")
        if let total, raw.count != total { return true }
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
        revision += 1
    }

    // MARK: - 本体ファイルの種類（lookup の結果を覚える）

    private static let extKey = "nzbMainExt.v1"

    /// 本体ファイルの拡張子（ts / mp4 / 7z …）。まだ調べていなければ nil
    func mainExt(_ id: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: Self.extKey) as? [String: String])?[id]
    }

    func setMainExt(_ ext: String, for id: String) {
        var d = UserDefaults.standard.dictionary(forKey: Self.extKey) as? [String: String] ?? [:]
        d[id] = ext
        if d.count > 3_000 { d = Dictionary(uniqueKeysWithValues: d.suffix(2_000).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(d, forKey: Self.extKey)
    }

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

    // MARK: - 名前の解釈（裏のスレッドで呼ぶ）

    private struct Parsed {
        let raw: NzbItemRaw
        let airDate: Date?
        let station: String
        let title: String
        let flags: [String]
        let reupload: Int
    }

    private nonisolated static func build(_ items: [NzbItemRaw]) -> (entries: [UsenetEntry], stations: [StationCount]) {
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
            entries.append(UsenetEntry(
                id: p.raw.id, name: p.raw.name, bytes: p.raw.bytes, airDate: p.airDate,
                station: p.station, title: p.title, flags: p.flags,
                alternates: sorted.dropFirst().map(\.raw),
                searchKey: normalize("\(p.station) \(p.title) \(day)")))
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
        return (entries, stations)
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
