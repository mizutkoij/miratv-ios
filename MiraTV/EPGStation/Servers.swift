import Foundation

/// 設定画面で入力された接続先（UserDefaults）から、そのつどクライアントを作る
enum Servers {
    private static func string(_ key: String, _ fallback: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? fallback
    }

    static var mirakurun: MirakurunClient? { MirakurunClient(string("mirakurunURL", Defaults.mirakurunURL)) }
    static var epgstation: EPGStationClient? { EPGStationClient(string("epgstationURL", Defaults.epgstationURL)) }

    static var chapters: ChapterClient? { ChapterClient(string("chapterURL", Defaults.chapterURL)) }

    /// web-bml（データ放送）のサーバー。未設定なら nil
    static var webBML: URL? {
        let s = string("webbmlURL", Defaults.webbmlURL).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !s.isEmpty, let u = URL(string: s), u.scheme != nil, u.host != nil else { return nil }
        return u
    }

    /// EPGStation に載っていない局（放送していない副チャンネル等）も一覧に出すか
    static var showInactiveChannels: Bool { UserDefaults.standard.bool(forKey: "showInactiveChannels") }
}

/// 録画予約の一覧と操作。番組表・番組詳細・録画画面が共有する
@MainActor
final class ReserveStore: ObservableObject {
    @Published private(set) var reserves: [ESReserve] = []
    @Published private(set) var error: String?
    @Published private(set) var busy = false

    func refresh() async {
        guard let es = Servers.epgstation else { error = "EPGStation の URL が設定されていません"; return }
        do { reserves = try await es.reserves(); error = nil }
        catch { self.error = describeError(error) }
    }

    func reserve(forProgram id: Int64) -> ESReserve? {
        reserves.first { $0.programId == id }
    }

    /// 予約を追加して、一覧を取り直す。失敗したら理由の文字列を返す
    func add(programId: Int64) async -> String? {
        guard let es = Servers.epgstation else { return "EPGStation の URL が設定されていません" }
        busy = true; defer { busy = false }
        do { try await es.addReserve(programId: programId) }
        catch { return describeError(error) }
        await refresh()
        return nil
    }

    /// ルールを追加。予約はサーバー側で順次作られるので、少し待ってから一覧を取り直す
    func addRule(_ rule: EPGStationClient.NewRule) async -> String? {
        guard let es = Servers.epgstation else { return "EPGStation の URL が設定されていません" }
        busy = true; defer { busy = false }
        do { try await es.addRule(rule) }
        catch { return describeError(error) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await refresh()
        return nil
    }

    func deleteRule(id: Int) async -> String? {
        guard let es = Servers.epgstation else { return "EPGStation の URL が設定されていません" }
        busy = true; defer { busy = false }
        do { try await es.deleteRule(id: id) }
        catch { return describeError(error) }
        await refresh()
        return nil
    }

    func cancel(reserveId: Int) async -> String? {
        guard let es = Servers.epgstation else { return "EPGStation の URL が設定されていません" }
        busy = true; defer { busy = false }
        do { try await es.deleteReserve(id: reserveId) }
        catch { return describeError(error) }
        await refresh()
        return nil
    }
}
