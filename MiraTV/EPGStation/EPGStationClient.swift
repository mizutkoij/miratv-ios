import Foundation

// EPGStation v2.10 の REST クライアント。仕様は実機の `/api/docs`（OpenAPI）と実測に基づく。
// 認証なし・Tailscale 内のみで使う前提。

// MARK: - Models（欠けたキーや型違いで全体が落ちないよう、ほぼ Optional）

struct ESChannel: Decodable, Hashable, Identifiable {
    let id: Int
    let serviceId: Int?
    let networkId: Int?
    let name: String
    let channelType: String?
    let remoteControlKeyId: Int?
    let hasLogoData: Bool?
}

struct ESProgram: Decodable, Hashable, Identifiable {
    let id: Int64
    let channelId: Int
    let startAt: Int64
    let endAt: Int64
    let isFree: Bool?
    let name: String?
    let description: String?
    let extended: String?
    let genre1: Int?
    let genre2: Int?
    let genre3: Int?
    let videoResolution: String?
    let audioComponentType: Int?
}

struct ESSchedule: Decodable {
    let channel: ESChannel
    let programs: [ESProgram]

    enum CodingKeys: String, CodingKey { case channel, programs }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channel = try c.decode(ESChannel.self, forKey: .channel)
        programs = (try? c.decode([LossyDecodable<ESProgram>].self, forKey: .programs))?.compactMap(\.value) ?? []
    }
}

struct ESReserve: Decodable, Hashable, Identifiable {
    let id: Int
    let ruleId: Int?
    let programId: Int64?
    let channelId: Int
    let startAt: Int64
    let endAt: Int64
    let name: String?
    let isSkip: Bool?
    let isConflict: Bool?
    let isOverlap: Bool?
    let isTimeSpecified: Bool?

    var start: Date { Date(timeIntervalSince1970: Double(startAt) / 1000) }
    var end: Date { Date(timeIntervalSince1970: Double(endAt) / 1000) }
}

struct ESVideoFile: Decodable, Hashable, Identifiable {
    let id: Int
    let name: String?
    /// ファイル名（フォルダ名は含まない）。CM 検出サービスがここからファイルを探す
    let filename: String?
    let type: String?     // "ts" | "encoded"
    let size: Int64?
}

struct ESRecorded: Decodable, Hashable, Identifiable {
    let id: Int
    let channelId: Int?
    let startAt: Int64
    let endAt: Int64
    let name: String?
    let description: String?
    let isRecording: Bool?
    let thumbnails: [Int]?
    let videoFiles: [ESVideoFile]?

    var start: Date { Date(timeIntervalSince1970: Double(startAt) / 1000) }
    var durationSeconds: Double { Double(endAt - startAt) / 1000 }
}

struct ESRule: Decodable, Hashable, Identifiable {
    let id: Int
    let isTimeSpecification: Bool?
    /// 実測: キー名は reservesCnt（予約件数）
    let reservesCnt: Int?
    let keyword: String?
    let channelIds: [Int]
    /// 曜日ビット（0x01 日 … 0x40 土）・開始時・範囲（時）。週指定なしは空
    let times: [Time]
    let enable: Bool

    struct Time: Decodable, Hashable { let week: Int?; let start: Int?; let range: Int? }

    enum CodingKeys: String, CodingKey { case id, isTimeSpecification, reservesCnt, searchOption, reserveOption }
    private struct Search: Decodable { let keyword: String?; let channelIds: [Int]?; let times: [Time]? }
    private struct Reserve: Decodable { let enable: Bool? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        isTimeSpecification = try? c.decodeIfPresent(Bool.self, forKey: .isTimeSpecification)
        reservesCnt = try? c.decodeIfPresent(Int.self, forKey: .reservesCnt)
        let s = try? c.decode(Search.self, forKey: .searchOption)
        keyword = s?.keyword
        channelIds = s?.channelIds ?? []
        times = s?.times ?? []
        enable = (try? c.decode(Reserve.self, forKey: .reserveOption))?.enable ?? true
    }
}

struct ESStorage: Decodable {
    let name: String?
    let available: Int64?
    let used: Int64?
    let total: Int64?
}

/// `/api/config` の streamConfig.live.hls（ライブ HLS の選択肢。index が mode になる）
struct ESLiveHLSModes {
    var names: [String]
}

enum ESError: LocalizedError {
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .http(let code, let body): "EPGStation が HTTP \(code) を返しました\(body.isEmpty ? "" : "：\(body)")"
        }
    }
}

// MARK: - Client

struct EPGStationClient {
    let baseURL: URL

    init?(_ string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: s), url.scheme != nil, url.host != nil else { return nil }
        baseURL = url
    }

    private func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var c = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url!
    }

    /// GET は一時的な失敗なら取り直す。POST / DELETE（予約の追加・削除）は二重に送らないよう 1 回だけ
    private func send(_ req: URLRequest) async throws -> Data {
        let (data, res) = try await Net.data(for: req, retries: (req.httpMethod ?? "GET") == "GET" ? 2 : 0)
        if let http = res as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ESError.http(http.statusCode, String(data: data.prefix(160), encoding: .utf8) ?? "")
        }
        return data
    }

    /// cacheKey を渡すと、取れた生データを端末に保存する（次回 `cached` ですぐ出せる）
    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], timeout: TimeInterval = 30,
                                   cacheKey: String? = nil) async throws -> T {
        var req = URLRequest(url: url(path, query))
        req.timeoutInterval = timeout
        let data = try await send(req)
        let value = try JSONDecoder().decode(T.self, from: data)
        if let cacheKey { DiskCache.save(data, key: cacheKey) }
        return value
    }

    /// `schedules(..., cacheKey:)` で保存した番組表
    static func cachedSchedules(key: String) -> [ESSchedule]? {
        DiskCache.decode([LossyDecodable<ESSchedule>].self, key: key)?.compactMap(\.value)
    }

    private static func ms(_ d: Date) -> String { String(Int64(d.timeIntervalSince1970 * 1000)) }

    // MARK: 番組表

    /// 期間内の番組表（全局）。2 時間で約 560KB・0.5 秒、24 時間で約 4MB（全波）
    func schedules(from: Date, to: Date, types: [String] = ["GR", "BS", "CS", "SKY"],
                   cacheKey: String? = nil) async throws -> [ESSchedule] {
        var q: [String: String] = ["startAt": Self.ms(from), "endAt": Self.ms(to), "isHalfWidth": "true",
                                   "GR": "false", "BS": "false", "CS": "false", "SKY": "false"]
        for t in types { q[t] = "true" }
        let list: [LossyDecodable<ESSchedule>] = try await get("api/schedules", q, timeout: 60, cacheKey: cacheKey)
        return list.compactMap(\.value)
    }

    /// 1 局の番組表（days 日ぶん）
    func schedule(channelId: Int, from: Date, days: Int) async throws -> ESSchedule? {
        let list: [LossyDecodable<ESSchedule>] = try await get(
            "api/schedules/\(channelId)",
            ["startAt": Self.ms(from), "days": String(days), "isHalfWidth": "true"], timeout: 45)
        return list.compactMap(\.value).first
    }

    // MARK: 予約

    func reserves() async throws -> [ESReserve] {
        struct R: Decodable { let reserves: [LossyDecodable<ESReserve>] }
        let r: R = try await get("api/reserves", ["isHalfWidth": "true", "limit": "200"])
        return r.reserves.compactMap(\.value)
    }

    /// 番組単位の録画予約。allowEndLack: 末尾の欠けを許容する（EPGStation の既定的な使い方）
    func addReserve(programId: Int64) async throws {
        var req = URLRequest(url: url("api/reserves"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["programId": programId, "allowEndLack": true])
        req.timeoutInterval = 20
        _ = try await send(req)
    }

    func deleteReserve(id: Int) async throws {
        var req = URLRequest(url: url("api/reserves/\(id)"))
        req.httpMethod = "DELETE"
        req.timeoutInterval = 20
        _ = try await send(req)
    }

    // MARK: ルール予約

    struct NewRule {
        var keyword: String
        var channelId: Int?          // nil = 放送波ぜんぶ
        var channelType: String      // "GR" / "BS" / "CS" / "SKY"（channelId が nil のときに使う）
        var weekMask: Int            // 0x01 日 … 0x40 土
        var startHour: Int?          // nil = 時間帯を限定しない
        var rangeHours: Int
        var avoidDuplicate: Bool
    }

    /// キーワード + 曜日 + 時間帯のルールを追加する。CM 抜き・保存先などは EPGStation の既定
    func addRule(_ r: NewRule) async throws {
        var search: [String: Any] = [
            "keyword": r.keyword, "name": true, "description": false, "extended": false,
            "keyCS": false, "keyRegExp": false, "ignoreKeyCS": false, "ignoreKeyRegExp": false,
            "ignoreName": false, "ignoreDescription": false, "ignoreExtended": false,
            "GR": false, "BS": false, "CS": false, "SKY": false, "isFree": false,
        ]
        if let id = r.channelId { search["channelIds"] = [id] }
        else if ["GR", "BS", "CS", "SKY"].contains(r.channelType) { search[r.channelType] = true }
        var time: [String: Any] = ["week": r.weekMask]
        if let h = r.startHour { time["start"] = h; time["range"] = max(r.rangeHours, 1) }
        search["times"] = [time]
        let body: [String: Any] = [
            "isTimeSpecification": false,
            "searchOption": search,
            "reserveOption": ["enable": true, "allowEndLack": true, "avoidDuplicate": r.avoidDuplicate],
        ]
        var req = URLRequest(url: url("api/rules"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30
        _ = try await send(req)
    }

    func deleteRule(id: Int) async throws {
        var req = URLRequest(url: url("api/rules/\(id)"))
        req.httpMethod = "DELETE"
        req.timeoutInterval = 20
        _ = try await send(req)
    }

    // MARK: 録画・ルール・容量

    func recorded(offset: Int = 0, limit: Int = 30) async throws -> (records: [ESRecorded], total: Int) {
        struct R: Decodable { let records: [LossyDecodable<ESRecorded>]; let total: Int? }
        // isReverse=true は「古い順」（実測）。新しい順にしたいので指定しない
        let r: R = try await get("api/recorded", ["isHalfWidth": "true",
                                                   "offset": String(offset), "limit": String(limit)])
        let recs = r.records.compactMap(\.value)
        return (recs, r.total ?? recs.count)
    }

    func rules() async throws -> [ESRule] {
        struct R: Decodable { let rules: [LossyDecodable<ESRule>] }
        let r: R = try await get("api/rules", ["limit": "100"])
        return r.rules.compactMap(\.value)
    }

    /// 空き容量（実測: {"items":[{name,available,used,total}]}）
    func storages() async throws -> [ESStorage] {
        struct R: Decodable { let items: [LossyDecodable<ESStorage>]? }
        let r: R = try await get("api/storages")
        return (r.items ?? []).compactMap(\.value)
    }

    func liveHLSModes() async throws -> ESLiveHLSModes {
        struct Cfg: Decodable {
            struct Stream: Decodable { let live: Live? }
            struct Live: Decodable { let hls: [String]? }
            let streamConfig: Stream?
        }
        let cfg: Cfg = try await get("api/config", timeout: 15)
        return ESLiveHLSModes(names: cfg.streamConfig?.live?.hls ?? [])
    }

    // MARK: URL

    func logoURL(channelId: Int) -> URL { url("api/channels/\(channelId)/logo") }
    func thumbnailURL(id: Int) -> URL { url("api/thumbnails/\(id)") }
    func videoURL(fileId: Int) -> URL { url("api/videos/\(fileId)") }
    /// ライブ HLS。mode は `/api/config` の streamConfig.live.hls の並び順（0 始まり）
    func liveHLSURL(channelId: Int, mode: Int) -> URL {
        url("api/streams/live/\(channelId)/hls", ["mode": String(mode)])
    }
}
