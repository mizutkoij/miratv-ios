import Foundation

/// homeserver の CM 検出サービス（server/chapterd.py）のクライアント。
/// 録画の音声の無音位置から CM ブロックを推定した結果を返す。初回は解析（約 1 分/時間）が走るので、ポーリングする
struct ChapterInfo: Decodable {
    let status: String            // pending / running / ready / error
    let progress: Double?
    let duration: Double?
    let cm: [[Double]]?           // [[start, end], ...]（秒、ファイル先頭 = 0）
    let error: String?

    /// CM ブロック（秒）
    var blocks: [(start: Double, end: Double)] {
        (cm ?? []).compactMap { $0.count == 2 ? (start: $0[0], end: $0[1]) : nil }
    }
}

/// 録画の字幕を文字にしたもの（server/chapterd.py の /captions）
struct CaptionLine: Decodable, Hashable, Identifiable {
    let time: Double
    let text: String
    var id: String { "\(time)-\(text)" }

    init(from decoder: Decoder) throws {        // [秒, "文字"]
        var c = try decoder.unkeyedContainer()
        time = try c.decode(Double.self)
        text = try c.decode(String.self)
    }
}

struct CaptionTextInfo: Decodable {
    let status: String            // pending / running / ready / error
    let progress: Double?
    let captions: [CaptionLine]?
    let error: String?
}

struct CaptionSearchResult: Decodable {
    let indexed: Int
    let results: [Hit]

    struct Hit: Decodable, Identifiable {
        /// videoFileId
        let id: Int
        /// 録画 ID（EPGStation の recordedId）。古いサーバーでは無い
        let rid: Int?
        let name: String?
        let hits: [CaptionLine]
        let count: Int?
    }
}

struct ChapterClient {
    let baseURL: URL

    init?(_ string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !s.isEmpty, let url = URL(string: s), url.scheme != nil, url.host != nil else { return nil }
        baseURL = url
    }

    /// 録画ファイルそのものを返す URL（Range 対応）。EPGStation を通さず homeserver のファイルを直接読むので軽い
    func rawURL(filename: String) -> URL {
        var c = URLComponents(url: baseURL.appending(path: "raw"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "name", value: filename)]
        return c.url!
    }

    /// 直接配信が使えるか（ファイルが見つかり Range が効くか）を HEAD で確かめる
    func rawAvailable(filename: String) async -> Bool {
        var req = URLRequest(url: rawURL(filename: filename))
        req.httpMethod = "HEAD"
        req.timeoutInterval = 4
        guard let (_, res) = try? await URLSession.shared.data(for: req), let http = res as? HTTPURLResponse else { return false }
        return http.statusCode == 200 && http.value(forHTTPHeaderField: "Accept-Ranges") == "bytes"
    }

    /// 字幕を文字で取り出す（初回は homeserver がファイルを 1 回読む。1 時間の番組で数十秒〜数分）。ポーリングする
    func captions(videoFileId: Int, filename: String, recordedId: Int) async throws -> CaptionTextInfo {
        var c = URLComponents(url: baseURL.appending(path: "captions/\(videoFileId)"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "name", value: filename), URLQueryItem(name: "rid", value: String(recordedId))]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 20
        let (data, res) = try await URLSession.shared.data(for: req)
        if let http = res as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(CaptionTextInfo.self, from: data)
    }

    /// 取り出し済みの録画すべてから探す（スペース区切りで AND。ひらがな・カタカナ、全角・半角は区別しない）
    func searchCaptions(_ q: String) async throws -> CaptionSearchResult {
        var c = URLComponents(url: baseURL.appending(path: "captions/search"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 20
        let (data, res) = try await URLSession.shared.data(for: req)
        if let http = res as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(CaptionSearchResult.self, from: data)
    }

    struct FollowInfo: Decodable {
        /// いま録れている長さ（秒）
        let duration: Double
        let size: Int64?
        /// まだ書き足されているか（false = 録画が終わった）
        let growing: Bool
    }

    /// 録画中の録画: いま録れている長さ
    func followInfo(filename: String) async throws -> FollowInfo {
        var c = URLComponents(url: baseURL.appending(path: "follow/info"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "name", value: filename)]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 10
        let (data, res) = try await URLSession.shared.data(for: req)
        if let http = res as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(FollowInfo.self, from: data)
    }

    /// 録画中の録画を t 秒から流し、書き足される分もそのまま流し続ける URL
    func followURL(filename: String, t: Double) -> URL {
        var c = URLComponents(url: baseURL.appending(path: "follow"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "name", value: filename), URLQueryItem(name: "t", value: String(format: "%.1f", max(t, 0)))]
        return c.url!
    }

    func chapters(videoFileId: Int, filename: String) async throws -> ChapterInfo {
        var c = URLComponents(url: baseURL.appending(path: "chapters/\(videoFileId)"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "name", value: filename)]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 20
        let (data, res) = try await URLSession.shared.data(for: req)
        if let http = res as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ChapterInfo.self, from: data)
    }
}
