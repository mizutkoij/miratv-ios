import Foundation

/// Mirakurun `/api/services` の 1 要素
struct MirakurunService: Decodable, Identifiable, Hashable {
    let id: Int
    let serviceId: Int
    let networkId: Int
    let name: String
    let type: Int?
    let remoteControlKeyId: Int?
    let channel: Channel?

    struct Channel: Decodable, Hashable {
        let type: String     // "GR" / "BS" / "CS" / "SKY"
        let channel: String
    }

    /// 0x01 = デジタルTV, 0xAD = 超高精細度4K専用TV。ラジオ・データ専用サービスは除外する
    var isTV: Bool { type == nil || type == 0x01 || type == 0xAD }
}

struct MirakurunClient {
    let baseURL: URL

    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else { return nil }
        baseURL = url
    }

    private var servicesCacheKey: String { "mirakurun-services-\(baseURL.host ?? "")-\(baseURL.port ?? 0)" }

    func services() async throws -> [MirakurunService] {
        var req = URLRequest(url: baseURL.appending(path: "api/services"))
        req.timeoutInterval = 30   // Tailscale が中継(DERP)経由だと遅いので長めに
        let (data, res) = try await Net.data(for: req)
        if let http = res as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let list = try JSONDecoder().decode([MirakurunService].self, from: data)
        DiskCache.save(data, key: servicesCacheKey)
        return list
    }

    /// 前回取れた局一覧（起動直後にすぐ出す用）
    func cachedServices() -> [MirakurunService]? {
        DiskCache.decode([MirakurunService].self, key: servicesCacheKey)
    }

    /// サービス単位の TS ストリーム。decode=1 で Mirakurun 側のデコーダ設定を使う
    func streamURL(for service: MirakurunService) -> URL {
        var c = URLComponents(url: baseURL.appending(path: "api/services/\(service.id)/stream"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "decode", value: "1")]
        return c.url!
    }

    /// 局ロゴ（PNG）。放送ロゴは白地・透過が多いので LogoTile の明るい枠に載せる
    func logoURL(for service: MirakurunService) -> URL {
        baseURL.appending(path: "api/services/\(service.id)/logo")
    }

    /// 1 局ぶんの番組表（約 7 日・約 0.5MB）。全局まとめて取ると 38MB・27 秒かかるので必ず局単位で
    func programs(for service: MirakurunService) async throws -> [MirakurunProgram] {
        var c = URLComponents(url: baseURL.appending(path: "api/programs"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "networkId", value: String(service.networkId)),
                        URLQueryItem(name: "serviceId", value: String(service.serviceId))]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 45
        let (data, res) = try await Net.data(for: req, retries: 1)
        if let http = res as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let list = try JSONDecoder().decode([LossyDecodable<MirakurunProgram>].self, from: data)
        return list.compactMap(\.value).sorted { $0.startAt < $1.startAt }
    }
}
