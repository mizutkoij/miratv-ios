import Foundation

/// Mirakurun から取った番組表の整理役。サーバーが局の絞り込みを守るか（守らず全局ぶんを返すか）を覚えて、
/// 守らないサーバーでは全局ぶんを 1 回だけ取って（同時に何本も取らない）、局ごとに分けて使い回す。
actor ProgramBulk {
    static let shared = ProgramBulk()

    private struct Entry { let at: Date; let byService: [Int: [MirakurunProgram]] }
    private var bulk: [String: Entry] = [:]
    /// 絞り込みを守らないと分かったサーバー
    private var ignoresFilter: Set<String> = []
    private var inflight: [String: Task<[MirakurunProgram], Error>] = [:]

    private static let ttl: TimeInterval = 10 * 60
    /// 全局ぶんを覚えるときは、これから 36 時間先までと、終わって 1 時間以内のものだけ（使うのはいま・次・1 日ぶん）
    private static let horizon: TimeInterval = 36 * 3600

    private func key(_ s: MirakurunService) -> Int { s.networkId &* 100_000 &+ s.serviceId }

    private func hit(_ base: String, _ service: MirakurunService) -> [MirakurunProgram]? {
        guard let e = bulk[base], Date().timeIntervalSince(e.at) < Self.ttl else { return nil }
        return e.byService[key(service)] ?? []
    }

    private func mine(_ list: [MirakurunProgram], _ service: MirakurunService) -> [MirakurunProgram] {
        list.filter { ($0.serviceId ?? service.serviceId) == service.serviceId && ($0.networkId ?? service.networkId) == service.networkId }
    }

    func programs(base: String, service: MirakurunService,
                  fetch: @escaping @Sendable () async throws -> [MirakurunProgram]) async throws -> [MirakurunProgram] {
        if let h = hit(base, service) { return h }
        // 絞り込みを守るか未確認、または守らないサーバー: 取得は 1 本ずつ。先に取っている分があれば待って、できたものを使う
        if !honors.contains(base), let t = inflight[base] {
            _ = try? await t.value
            if let h = hit(base, service) { return h }
        }
        let task = Task { try await fetch() }
        let gated = !honors.contains(base)
        if gated { inflight[base] = task }
        defer { if gated { inflight[base] = nil } }
        let list = try await task.value

        let owners = Set(list.map { ($0.networkId ?? service.networkId) &* 100_000 &+ ($0.serviceId ?? service.serviceId) })
        if owners.count > 1 {
            ignoresFilter.insert(base)
            let now = Date()
            let from = now.addingTimeInterval(-3600), to = now.addingTimeInterval(Self.horizon)
            var by: [Int: [MirakurunProgram]] = [:]
            for p in list {
                let start = Date(timeIntervalSince1970: Double(p.startAt) / 1000)
                let end = Date(timeIntervalSince1970: Double(p.startAt + p.duration) / 1000)
                guard end >= from, start <= to else { continue }
                by[(p.networkId ?? service.networkId) &* 100_000 &+ (p.serviceId ?? service.serviceId), default: []].append(p)
            }
            for k in by.keys { by[k]?.sort { $0.startAt < $1.startAt } }
            bulk[base] = Entry(at: now, byService: by)
            return by[key(service)] ?? []
        }
        honors.insert(base)
        return mine(list, service)
    }

    /// 絞り込みを守ると分かったサーバー（同時に取ってよい）
    private var honors: Set<String> = []
}
