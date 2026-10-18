import Foundation

// radio-search（VPS2 の server/radio-search/radio_search.py）のクライアント。
// radiko.db の約 50 万件の過去番組を、サーバー側の全文検索で 50 件ずつ返してもらう。端末には全件を持たない。

struct RadioSearchHit: Decodable, Identifiable, Hashable {
    let id: Int
    /// `/api/archive/play` に渡す nzb 名
    let nzb: String
    /// radiko の局 ID（TBS など）
    let station: String
    let title: String
    let pfm: String?
    /// "2026-07-23T17:00:00+09:00"
    let onair: String
    let minutes: Int
    /// nzb ファイルが実際にあって再生できる見込み（古い分は元の nzb が失われていて false）
    let playable: Bool
    let thumbnail: String?

    var dateText: String {
        // 2026-07-23T17:00:00+09:00 → 7/23 17:00
        guard onair.count >= 16 else { return onair }
        let d = onair.dropFirst(5).prefix(5).replacingOccurrences(of: "-", with: "/")
        let t = onair.dropFirst(11).prefix(5)
        let dd = d.split(separator: "/").map { String(Int($0) ?? 0) }.joined(separator: "/")
        return "\(dd) \(t)"
    }

    /// RadioPlayer.playArchive に渡す形。番組の長さ（頭 25 秒の継ぎ足し判定に使う）は開始時刻 + 分で作る
    var scheduleItem: RadioScheduleItem {
        let hhmm = onair.count >= 16 ? String(onair.dropFirst(11).prefix(5)) : "--:--"
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        var end = hhmm
        if parts.count == 2 {
            let t = parts[0] * 60 + parts[1] + minutes
            end = String(format: "%02d:%02d", (t / 60) % 24, t % 60)
        }
        return RadioScheduleItem(ft: RadioTime(raw: hhmm), to: RadioTime(raw: end), title: title, pfm: pfm,
                                 thumbnail: thumbnail, nzb: nzb)
    }
}

struct RadioSearchResult: Decodable {
    let ready: Bool?
    let total: Int
    let totalCapped: Bool?
    let items: [RadioSearchHit]
}

struct RadioSearchStation: Decodable, Hashable {
    let id: String
    let count: Int
}

struct RadioSearchClient {
    let baseURL: URL

    init?(_ string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !s.isEmpty, let url = URL(string: s), url.scheme != nil, url.host != nil else { return nil }
        baseURL = url
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        var c = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        c.queryItems = query
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 15
        let (data, res) = try await Net.data(for: req)
        if let http = res as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func search(q: String, station: String?, playableOnly: Bool, newestFirst: Bool,
                from: Date? = nil, to: Date? = nil, limit: Int = 50, offset: Int = 0) async throws -> RadioSearchResult {
        var items = [URLQueryItem(name: "q", value: q),
                     URLQueryItem(name: "sort", value: newestFirst ? "new" : "old"),
                     URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "offset", value: String(offset))]
        if let station { items.append(URLQueryItem(name: "station", value: station)) }
        if playableOnly { items.append(URLQueryItem(name: "playable", value: "1")) }
        if let from { items.append(URLQueryItem(name: "from", value: Self.day.string(from: from))) }
        if let to { items.append(URLQueryItem(name: "to", value: Self.day.string(from: to))) }
        return try await get("search", items)
    }

    func stations(q: String, playableOnly: Bool) async throws -> [RadioSearchStation] {
        struct R: Decodable { let stations: [RadioSearchStation] }
        var items = [URLQueryItem(name: "q", value: q)]
        if playableOnly { items.append(URLQueryItem(name: "playable", value: "1")) }
        let r: R = try await get("stations", items)
        return r.stations
    }
}
