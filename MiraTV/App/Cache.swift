import Foundation
import SwiftUI
import UIKit

// 個人用アプリなので、接続先も局の顔ぶれもほぼ変わらない。
// 前回の取得結果を端末に保存しておき、起動直後や画面を開いた直後はそれをすぐ表示して、裏で取り直す。
// （「接続中…」で待たせない。取り直しに失敗しても、前回の内容のまま使える）

// MARK: - 端末内の保存

enum DiskCache {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("MiraTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func file(_ key: String) -> URL {
        let safe = key.map { c -> Character in (c.isASCII && (c.isLetter || c.isNumber)) || c == "-" || c == "_" ? c : "_" }
        return dir.appendingPathComponent(String(safe))
    }

    static func save(_ data: Data, key: String) {
        try? data.write(to: file(key), options: .atomic)
    }

    static func load(_ key: String) -> Data? {
        try? Data(contentsOf: file(key))
    }

    static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = load(key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// 保存してからの経過秒。無ければ nil
    /// 古い保存分を消す（番組表は放送波×日で増えていくため）。起動時に 1 回
    static func prune(olderThan seconds: TimeInterval = 10 * 86400) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-seconds)
        for f in files {
            let at = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if at < limit { try? fm.removeItem(at: f) }
        }
    }

    static func age(_ key: String) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file(key).path),
              let at = attrs[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(at)
    }
}

// MARK: - 一時的な失敗の取り直し

enum Net {
    /// タイムアウト・接続断・5xx のような一時的な失敗なら、少し待って送り直す。
    /// Tailscale が中継（DERP）経由になった直後などに 1 回目だけ落ちることが多いため。
    /// 何度送っても害のない要求（GET など）に使う
    /// retryTimeouts = false: 応答に長くかかる要求（アーカイブの準備など）は、タイムアウトでは送り直さない
    static func data(for req: URLRequest, retries: Int = 2, retryTimeouts: Bool = true) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            do {
                let (data, res) = try await URLSession.shared.data(for: req)
                if let http = res as? HTTPURLResponse, [500, 502, 503, 504].contains(http.statusCode), attempt < retries {
                    attempt += 1
                    DebugLog.log("net", "再試行 \(attempt)/\(retries) HTTP \(http.statusCode) \(req.url?.path ?? "")")
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
                    continue
                }
                return (data, res)
            } catch let e as URLError where isTransient(e) && attempt < retries && (retryTimeouts || e.code != .timedOut) {
                attempt += 1
                DebugLog.log("net", "再試行 \(attempt)/\(retries) URLError \(e.code.rawValue) \(req.url?.path ?? "")")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
        }
    }

    static func isTransient(_ e: URLError) -> Bool {
        switch e.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .notConnectedToInternet, .badServerResponse, .resourceUnavailable, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}

// MARK: - 局ロゴなどの画像

/// 画像のキャッシュ（メモリ＋端末）。局ロゴはまず変わらないので、一度取れたら次からは通信しない
final class ImageStore: @unchecked Sendable {
    static let shared = ImageStore()
    private let memory = NSCache<NSURL, UIImage>()
    private let lock = NSLock()
    /// このセッションで取れなかった URL（ロゴの無い局で毎回取りに行かない）
    private var missing = Set<URL>()

    private func key(_ url: URL) -> String { "img-" + url.absoluteString }

    func cached(_ url: URL) -> UIImage? {
        if let img = memory.object(forKey: url as NSURL) { return img }
        if let data = DiskCache.load(key(url)), let img = UIImage(data: data) {
            memory.setObject(img, forKey: url as NSURL)
            return img
        }
        return nil
    }

    func load(_ url: URL) async -> UIImage? {
        if let img = cached(url) { return img }
        lock.lock(); let isMissing = missing.contains(url); lock.unlock()
        if isMissing { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        guard let (data, res) = try? await Net.data(for: req, retries: 1) else { return nil }
        let ok = (res as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
        guard ok, let img = UIImage(data: data) else {
            lock.lock(); missing.insert(url); lock.unlock()
            return nil
        }
        DiskCache.save(data, key: key(url))
        memory.setObject(img, forKey: url as NSURL)
        return img
    }
}

/// AsyncImage の代わり。キャッシュにあれば最初の描画から出す
struct CachedImage: View {
    let url: URL?
    @State private var image: UIImage?

    init(url: URL?) {
        self.url = url
        _image = State(initialValue: url.flatMap { ImageStore.shared.cached($0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            // 同じ View のまま URL だけ変わる（再生画面の選局など）ことがあるので、毎回 URL から引き直す
            guard let url else { image = nil; return }
            if let hit = ImageStore.shared.cached(url) { image = hit; return }
            image = nil
            image = await ImageStore.shared.load(url)
        }
    }
}
