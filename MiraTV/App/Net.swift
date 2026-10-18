import Foundation

/// 個人用アプリなので、一覧や番組表は「前回の結果をすぐ出して、裏で取り直す」。
/// Tailscale が中継（DERP）経由だと時々詰まるので、1 回の待ちは短く切って自動で再試行する
enum Net {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 6
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    /// 1 回の試行の上限（秒）。元の timeout がこれより長くても、詰まったら切って再試行する方が早く直る
    private static let attemptCap: TimeInterval = 15

    /// 通信の失敗（タイムアウト・切断・5xx）は短い間隔で再試行する。POST/DELETE は二重実行を避けるため再試行しない
    static func data(_ req: URLRequest, retries: Int = 2) async throws -> (Data, URLResponse) {
        var req = req
        req.timeoutInterval = min(req.timeoutInterval, attemptCap)
        let idempotent = (req.httpMethod ?? "GET") == "GET" || req.httpMethod == "HEAD"
        var attempt = 0
        while true {
            do {
                let (data, res) = try await session.data(for: req)
                if let http = res as? HTTPURLResponse, http.statusCode >= 500, idempotent, attempt < retries {
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(400_000_000 * attempt))
                    continue
                }
                return (data, res)
            } catch {
                let retriable = (error as? URLError).map {
                    [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed].contains($0.code)
                } ?? false
                if Task.isCancelled || !retriable || !idempotent || attempt >= retries { throw error }
                attempt += 1
                DebugLog.log("net", "再試行 \(attempt)/\(retries) \(req.url?.path ?? "") \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: UInt64(400_000_000 * attempt))
            }
        }
    }

    // MARK: - 前回の結果（ディスク）

    private static var dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "netcache")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func file(_ key: String) -> URL {
        dir.appending(path: key.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined() + ".json")
    }

    static func store(_ data: Data, key: String) { try? data.write(to: file(key), options: .atomic) }

    /// 前回成功したときの応答。max 秒より古ければ nil
    static func stored(key: String, maxAge: TimeInterval = 7 * 86400) -> Data? {
        let f = file(key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
              let at = attrs[.modificationDate] as? Date, Date().timeIntervalSince(at) < maxAge else { return nil }
        return try? Data(contentsOf: f)
    }

    static func storedValue<T: Decodable>(_ type: T.Type, key: String, maxAge: TimeInterval = 7 * 86400) -> T? {
        stored(key: key, maxAge: maxAge).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
