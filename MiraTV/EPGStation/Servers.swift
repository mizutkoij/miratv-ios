import Foundation

/// 設定画面で入力された接続先（UserDefaults）から、そのつどクライアントを作る
enum Servers {
    private static func string(_ key: String, _ fallback: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? fallback
    }

    static var mirakurun: MirakurunClient? { MirakurunClient(string("mirakurunURL", Defaults.mirakurunURL)) }
    static var epgstation: EPGStationClient? { EPGStationClient(string("epgstationURL", Defaults.epgstationURL)) }

    static var chapters: ChapterClient? { ChapterClient(string("chapterURL", Defaults.chapterURL)) }

    /// 自前の中継（streamd）。未設定なら nil（音声のみは Mirakurun の原画質ストリームから映像を捨てる方式になる）
    static var streamd: URL? {
        let s = string("streamdURL", Defaults.streamdURL).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !s.isEmpty, let u = URL(string: s), u.scheme != nil, u.host != nil else { return nil }
        return u
    }

    /// streamd の音声だけのストリーム（映像・データ放送の TS パケットを中継で捨てる。約 0.2〜0.4Mbps）
    static func streamdAudioURL(_ service: MirakurunService) -> URL? {
        guard let base = streamd,
              var c = URLComponents(url: base.appending(path: "live/\(service.id)"), resolvingAgainstBaseURL: false) else { return nil }
        c.queryItems = [URLQueryItem(name: "video", value: "0")]
        return c.url
    }

    /// streamd の追っかけ用バッファ（/timeshift/<局>/...）
    static func timeshiftURL(_ service: MirakurunService, _ action: String, from: Double? = nil, bufferID: Int64? = nil) -> URL? {
        guard let base = streamd,
              var c = URLComponents(url: base.appending(path: "timeshift/\(service.id)/\(action)"), resolvingAgainstBaseURL: false)
        else { return nil }
        var q = [URLQueryItem(name: "client", value: deviceID)]
        if let from { q.append(URLQueryItem(name: "from", value: String(format: "%.1f", from))) }
        if let bufferID { q.append(URLQueryItem(name: "id", value: String(bufferID))) }
        c.queryItems = q
        return c.url
    }

    /// この端末の ID（streamd が「どの端末が見ているか」を数えるため。中身に意味はない）
    static var deviceID: String {
        if let s = UserDefaults.standard.string(forKey: "deviceID") { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: "deviceID")
        return s
    }

    /// web-bml（データ放送）のサーバー。未設定なら nil
    static var webBML: URL? {
        let s = string("webbmlURL", Defaults.webbmlURL).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !s.isEmpty, let u = URL(string: s), u.scheme != nil, u.host != nil else { return nil }
        return u
    }

    /// nzb-dl（Usenet のアーカイブ）。URL か API キーが空なら nil
    static var nzbdl: NzbDlClient? {
        NzbDlClient(string("nzbdlURL", Defaults.nzbdlURL), apiKey: string("nzbdlKey", ""))
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
