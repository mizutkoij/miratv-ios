import Foundation

// VPS1 の nzb-dl（Go, :8083, Tailscale のみ）のクライアント。読み取りの API だけを使う。
// 仕様は docs/nzb-stream-playback.md（2026-10-19 の実測）。応答の形は細部が未確認なので、
// JSONSerialization で寛容に読む（キー名の揺れ・数値/文字列の揺れを吸収する）。
//
// - GET /api/items?status=on&limit=&offset=   一覧（カテゴリで絞らない。アップロード順の新しい順）
// - GET /api/items/lookup?folder=<名前から .nzb を除いたもの>  中のファイル名
// - GET /api/stream/<id>?apikey=                           本体ファイル（Range 可）

/// 一覧の 1 件（サーバーの生の値。解釈は UsenetCatalog で行う）
struct NzbItemRaw: Codable, Hashable {
    let id: String
    let name: String
    let bytes: Int64
    /// アップロード時刻（epoch 秒）。放送日時ではない
    let created: Double
    /// nzb-dl のカテゴリ（tv / uncategorized / radio …）。古い保存分には無い
    var category: String? = nil
}

struct NzbItemsPage {
    let items: [NzbItemRaw]
    let total: Int?
}

/// item の中のファイル
struct NzbFile: Hashable {
    let name: String
    let bytes: Int64?

    var ext: String { (name as NSString).pathExtension.lowercased() }
    /// par2・nfo・sfv などの付属ファイル（par2 のボリュームも拡張子は par2）
    var isAuxiliary: Bool {
        ["par2", "nfo", "sfv", "nzb", "txt", "jpg", "png"].contains(ext)
    }
    /// 中身の種類。分割アーカイブ（.7z.001 / .zip.001 / .r00 / .part01.rar）はアーカイブとして扱う
    var kind: String {
        let lower = name.lowercased()
        let e = ext
        if !e.isEmpty && e.allSatisfy(\.isNumber) {
            if lower.contains(".7z.") { return "7z" }
            if lower.contains(".zip.") { return "zip" }
            if lower.contains(".rar.") { return "rar" }
        }
        if e.count == 3, e.hasPrefix("r"), e.dropFirst().allSatisfy(\.isNumber) { return "rar" }
        return e
    }
}

struct NzbDlClient {
    let baseURL: URL
    let apiKey: String

    init?(_ string: String, apiKey: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !key.isEmpty, let url = URL(string: s), url.scheme != nil, url.host != nil else { return nil }
        baseURL = url
        self.apiKey = key
    }

    struct HTTPError: LocalizedError {
        let code: Int
        let path: String
        var errorDescription: String? {
            code == 401 ? "nzb-dl: API キーが違います（401）" : "nzb-dl: HTTP \(code) \(path)"
        }
    }

    private func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        c.queryItems = query + [URLQueryItem(name: "apikey", value: apiKey)]
        // "+" はクエリで空白に読まれることがあるので、念のため符号化しておく
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    private func getJSON(_ path: String, _ query: [URLQueryItem] = [], timeout: TimeInterval = 20) async throws -> Any {
        var req = URLRequest(url: url(path, query))
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, res) = try await Net.data(for: req)
        let code = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw HTTPError(code: code, path: path) }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - 一覧

    /// category = nil: カテゴリで絞らない（tv に加えて uncategorized も、約 1,000 件。実測 2026-10-19: 全体 80,086 / tv 75,811 /
    /// uncategorized 991 / radio 157）。radio は一覧に出さない（UsenetCatalog 側で除く）
    func items(category: String? = nil, status: String = "on", limit: Int, offset: Int) async throws -> NzbItemsPage {
        var q: [URLQueryItem] = []
        if let category { q.append(URLQueryItem(name: "category", value: category)) }
        q += [
            URLQueryItem(name: "status", value: status),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        let json = try await getJSON("api/items", q, timeout: 30)
        let list: [Any]
        var total: Int?
        if let arr = json as? [Any] {
            list = arr
        } else if let obj = json as? [String: Any] {
            list = (obj["items"] ?? obj["data"] ?? obj["results"] ?? obj["rows"]) as? [Any] ?? []
            total = Self.int(obj["total"] ?? obj["count"])
        } else {
            list = []
        }
        let items = list.compactMap { ($0 as? [String: Any]).flatMap(Self.item) }
        return NzbItemsPage(items: items, total: total)
    }

    private static func item(_ d: [String: Any]) -> NzbItemRaw? {
        guard let id = string(d["id"] ?? d["item_id"]), !id.isEmpty,
              let name = string(d["name"] ?? d["title"]), !name.isEmpty else { return nil }
        let bytes = int64(d["total_bytes"] ?? d["bytes"] ?? d["size"]) ?? 0
        let created = time(d["created_at"] ?? d["enabled_at"]) ?? 0
        return NzbItemRaw(id: id, name: name, bytes: bytes, created: created, category: string(d["category"]))
    }

    // MARK: - 中のファイル

    /// item の中のファイル一覧。name は .nzb 付きでもよい
    func files(itemName name: String) async throws -> [NzbFile] {
        let folder = name.lowercased().hasSuffix(".nzb") ? String(name.dropLast(4)) : name
        let json = try await getJSON("api/items/lookup", [URLQueryItem(name: "folder", value: folder)], timeout: 10)
        guard let obj = json as? [String: Any] else { return [] }
        let item = obj["item"] as? [String: Any]
        let raw = (obj["files"] ?? item?["files"]) as? [Any] ?? []
        return raw.compactMap { f in
            if let s = f as? String { return NzbFile(name: s, bytes: nil) }
            guard let d = f as? [String: Any],
                  let n = Self.string(d["name"] ?? d["filename"] ?? d["file"] ?? d["subject"]) else { return nil }
            return NzbFile(name: n, bytes: Self.int64(d["bytes"] ?? d["size"] ?? d["total_bytes"]))
        }
    }

    /// 再生する本体（付属ファイル以外で一番大きいもの。大きさが分からなければ最初のもの）
    static func mainFile(_ files: [NzbFile]) -> NzbFile? {
        let media = files.filter { !$0.isAuxiliary }
        return media.max { ($0.bytes ?? 0) < ($1.bytes ?? 0) } ?? media.first
    }

    // MARK: - 再生

    /// 本体ファイルのストリーム（Range 可）。長い全角のパスを符号化しなくてよい短い URL
    func streamURL(id: String) -> URL {
        url("api/stream/\(id)")
    }

    // MARK: - 値の寛容な読み取り

    private static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    private static func int(_ v: Any?) -> Int? { int64(v).map { Int($0) } }

    private static func int64(_ v: Any?) -> Int64? {
        switch v {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s)
        default: return nil
        }
    }

    /// epoch 秒 / epoch ミリ秒 / ISO8601 / "yyyy-MM-dd HH:mm:ss"（sqlite の既定）
    private static func time(_ v: Any?) -> Double? {
        if let n = v as? NSNumber {
            let x = n.doubleValue
            return x > 100_000_000_000 ? x / 1000 : x
        }
        guard let s = v as? String, !s.isEmpty else { return nil }
        if let x = Double(s) { return x > 100_000_000_000 ? x / 1000 : x }
        if let d = iso.date(from: s) ?? isoFrac.date(from: s) { return d.timeIntervalSince1970 }
        if let d = sqliteFormat.date(from: s) { return d.timeIntervalSince1970 }
        return nil
    }

    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let sqliteFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
