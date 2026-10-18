import Foundation

// radio-web (自宅/VPS の Python サーバー) の API クライアント。
// 認証なし・CORS * なので Tailscale 経由のみで使う前提。
// 仕様は 2026-10-16 の調査メモ（server.py 読解＋実測）に基づく。未検証の箇所は「要確認」コメント付き。

// MARK: - Models

enum RadioSource: String, Decodable, CaseIterable {
    case radiko, nhk, listenradio, manual, fmplapla, jcba
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RadioSource(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .radiko: "radiko"
        case .nhk: "NHK"
        case .listenradio: "ListenRadio"
        case .manual: "その他"
        case .fmplapla: "FMぷらぷら"
        case .jcba: "JCBA"
        case .unknown: "不明"
        }
    }
}

struct RadioProgramBrief: Decodable, Hashable {
    let ft: RadioTime?
    let to: RadioTime?
    let title: String?
    let pfm: String?
    let img: String?
}

struct RadioStation: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let source: RadioSource
    let region: String?
    let pref: String?
    let city: String?
    let logo: String?
    let current: RadioProgramBrief?
    let next: RadioProgramBrief?
    /// アーカイブ用の局キー（例 "radiko:802" / "nhk:R1"）。型が揺れるので文字列化して持つ（要確認）
    let archiveStation: LenientString?
    let streamUrl: String?
    let streamKind: String?       // "hls" | "audio"
    let fmplaplaStation: String?
    let jcbaSlug: String?
    let area: String?             // NHK
    let band: String?             // NHK: r1 | fm

    /// 同じ id が別ソースに存在しうるので一意キーはソース込みで
    var key: String { "\(source.rawValue):\(id)" }
}

struct RadioCatalog: Decodable {
    /// サーバー側のキー名は "radiko" だが全ソース混在
    let stations: [RadioStation]
    let regionOrder: [String]

    enum CodingKeys: String, CodingKey { case radiko, regionOrder }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stations = (try? c.decode([LossyDecodable<RadioStation>].self, forKey: .radiko))?.compactMap(\.value) ?? []
        regionOrder = (try? c.decode([String].self, forKey: .regionOrder)) ?? []
    }
}

struct RadioScheduleItem: Decodable, Identifiable, Hashable {
    let ft: RadioTime
    let to: RadioTime
    let title: String
    let pfm: String?
    let thumbnail: String?
    /// アーカイブがある番組だけ入る。`/api/archive/play` に渡す
    let nzb: String?

    var id: String { "\(ft.raw)-\(title)" }
    var isArchived: Bool { nzb?.isEmpty == false }

    /// 番組の長さ（秒）。schedule API の ft/to は "05:00" のような HH:mm（実測）。日跨ぎ（23:00→00:00）は +24h
    var lengthSeconds: Double? {
        func minutes(_ t: RadioTime) -> Int? {
            let p = t.raw.split(separator: ":")
            guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
            return h * 60 + m
        }
        guard let a = minutes(ft), let b = minutes(to) else { return nil }
        return Double(((b - a) + 24 * 60) % (24 * 60)) * 60
    }
}

struct RadioSchedule: Decodable {
    let items: [RadioScheduleItem]
    let supportsPastDates: Bool?

    enum CodingKeys: String, CodingKey { case items, supportsPastDates }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decode([LossyDecodable<RadioScheduleItem>].self, forKey: .items))?.compactMap(\.value) ?? []
        supportsPastDates = try? c.decode(Bool.self, forKey: .supportsPastDates)
    }
}

struct RadioArchiveHit: Decodable, Identifiable, Hashable {
    let source: String?
    let title: String
    let sub: String?
    let station: String?
    let thumbnail: String?
    let onair: String?
    let nzb: String
    var id: String { nzb }
}

struct RadioArchiveTicket: Decodable {
    let token: String
    let url: String
}

struct RadioNowPlaying: Decodable {
    let subtitle: String?
    let performer: String?
    let thumbnail: String?
}

// MARK: - Client

struct RadioWebClient {
    let baseURL: URL

    init?(_ string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: s), url.host != nil else { return nil }
        baseURL = url
    }

    func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var c = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url!
    }

    /// 相対パス（"/archive/stream/xxx" など）をサーバー基準の絶対 URL に
    func resolve(_ pathOrURL: String) -> URL? {
        if let u = URL(string: pathOrURL), u.scheme != nil { return u }
        return URL(string: pathOrURL, relativeTo: baseURL)?.absoluteURL
    }

    // 読み取り系
    func stations() async throws -> RadioCatalog { try await get("api/stations", cacheKey: "radio-stations") }

    /// 前回取れた局一覧。局の構成は滅多に変わらないので、画面を開いた瞬間にこれを出す
    static func cachedStations() -> RadioCatalog? { Net.storedValue(RadioCatalog.self, key: "radio-stations", maxAge: 90 * 86400) }

    func nowPlaying(radikoId: String) async throws -> RadioNowPlaying {
        try await get("api/nowplaying/radiko/\(radikoId)")
    }

    /// 日付は 05:00〜翌 05:00 区切り。過去日もOK（radiko は nzb 付きで返る）
    func schedule(source: RadioSource, station: String, date: Date) async throws -> RadioSchedule {
        try await get("api/station/schedule", ["source": source.rawValue, "station": station, "date": Self.dayFormatter.string(from: date)],
                      cacheKey: "radio-sched-\(source.rawValue)-\(station)-\(Self.dayFormatter.string(from: date))")
    }

    /// q / date / region のどれかが必須（空だと results:[]）。radiko はサーバーに実ファイルが残っている回のみ
    func archiveSearch(station: String?, q: String?, date: Date?) async throws -> [RadioArchiveHit] {
        var query: [String: String] = [:]
        if let station { query["station"] = station }
        if let q, !q.isEmpty { query["q"] = q }
        if let date { query["date"] = Self.dayFormatter.string(from: date) }
        struct R: Decodable { let results: [LossyDecodable<RadioArchiveHit>] }
        let r: R = try await get("api/archive/search", query)
        return r.results.compactMap(\.value)
    }

    // アーカイブ再生
    /// 初回は usenet から取得＋remux で 40 秒前後かかる。タイムアウトは長めに
    func archivePlay(nzb: String) async throws -> RadioArchiveTicket {
        try await post("api/archive/play", ["nzb": nzb], timeout: 180)
    }

    /// 次の回を裏で準備（fire-and-forget）
    func archivePrefetch(nzb: String) {
        Task { _ = try? await post("api/archive/prefetch", ["nzb": nzb], timeout: 10) as EmptyResponse }
    }

    /// トークンの寿命は約 15 秒。再生直前に呼ぶ（Ogg なので AVPlayer では鳴らない → FFmpeg エンジン行き）
    func fmplaplaResolve(station: String) async throws -> URL {
        struct R: Decodable { let url: String }
        let r: R = try await get("api/fmplapla/resolve", ["station": station])
        guard let u = URL(string: r.url) else { throw URLError(.badURL) }
        return u
    }

    // MARK: HTTP

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], cacheKey: String? = nil) async throws -> T {
        var req = URLRequest(url: url(path, query))
        req.timeoutInterval = 45   // 1 回の試行は Net が 15 秒で切って再試行する
        return try await send(req, cacheKey: cacheKey)
    }

    private func post<T: Decodable>(_ path: String, _ body: [String: String], timeout: TimeInterval) async throws -> T {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = timeout
        return try await send(req)
    }

    private func send<T: Decodable>(_ req: URLRequest, cacheKey: String? = nil) async throws -> T {
        let (data, res) = try await Net.data(req)
        if let http = res as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RadioWebError.http(http.statusCode)
        }
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        let value = try JSONDecoder().decode(T.self, from: data)
        if let cacheKey { Net.store(data, key: cacheKey) }
        return value
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

enum RadioWebError: LocalizedError {
    case http(Int)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): "radio-web がエラーを返しました (HTTP \(code))"
        case .unsupported(let why): why
        }
    }
}

struct EmptyResponse: Decodable { init() {} }

// MARK: - Lenient decoding helpers

/// 配列の 1 要素が壊れていても全体を落とさない
struct LossyDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// 文字列・数値・真偽値のどれで来ても文字列として受ける
struct LenientString: Decodable, Hashable {
    let value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let b = try? c.decode(Bool.self) { value = b ? "true" : "" }
        else { value = "" }
    }
}

/// radiko 形式 "yyyyMMddHHmmss"・ISO8601・epoch 秒のいずれも受ける（実フォーマット要確認）
struct RadioTime: Decodable, Hashable {
    let raw: String
    let date: Date?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) {
            raw = String(Int(n)); date = Date(timeIntervalSince1970: n); return
        }
        let s = try c.decode(String.self)
        raw = s
        date = RadioTime.compact.date(from: s)
            ?? RadioTime.compactMin.date(from: s)
            ?? ISO8601DateFormatter().date(from: s)
    }

    private static func fmt(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.timeZone = TimeZone(identifier: "Asia/Tokyo")
        d.dateFormat = f
        return d
    }
    private static let compact = fmt("yyyyMMddHHmmss")
    private static let compactMin = fmt("yyyyMMddHHmm")
}
