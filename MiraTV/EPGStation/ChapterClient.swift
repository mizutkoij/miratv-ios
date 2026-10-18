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
