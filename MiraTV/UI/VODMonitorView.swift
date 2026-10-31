import SwiftUI
import AVKit

/// VOD Monitor（homeserver の jod-vod-monitor、:36197）の一覧。ライブ（J-Sports・FOD・虎テレ・GIANTS TV・Rakuten）と、
/// J-Sports / GIANTS TV のオンデマンドを日付・チャンネルごとに並べ、タップで HLS を再生する。
/// モニターのページ（HTML）を読んで一覧を作るので、モニター側の変更は要らない

struct VODItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case direct(URL)        // m3u8 の直 URL
        case giants(String)     // contentId（モニターの /api/giantstv-play で URL を引く）
        case easysports(String) // mediaId（/api/easysports-play）
        case mpd(URL)           // DASH（AVPlayer では再生できない）
    }
    let id: String
    let title: String
    let time: String
    let sub: String
    let thumb: URL?
    let kind: Kind
    let live: Bool
}

struct VODGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let items: [VODItem]
}

struct VODSection: Identifiable, Hashable {
    let id: String
    let title: String
    let isLive: Bool
    let groups: [VODGroup]
}

enum VODMonitor {
    static var baseURL: URL? {
        let s = (UserDefaults.standard.string(forKey: "vodMonitorURL") ?? Defaults.vodMonitorURL)
            .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: s)
    }

    static func fetch() async throws -> [VODSection] {
        guard let base = baseURL else { throw URLError(.badURL) }
        var req = URLRequest(url: base)
        req.timeoutInterval = 30
        let (data, res) = try await URLSession.shared.data(for: req)
        if let http = res as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        let html = String(decoding: data, as: UTF8.self)
        var out = await Task.detached(priority: .userInitiated) { parse(html, base: base) }.value
        // EasySports はモニターのページでは別画面（/vod-test）なので、その JSON から一覧を作る
        if let es = await easysports(base: base) {
            // メインのページにも 1 件だけ EasySports が混ざっているので、重複しないよう外す
            out = out.compactMap { sec in
                let groups = sec.groups.compactMap { g -> VODGroup? in
                    let items = g.items.filter { if case .easysports = $0.kind { return false } else { return true } }
                    return items.isEmpty ? nil : VODGroup(id: g.id, title: g.title, items: items)
                }
                return groups.isEmpty ? nil : VODSection(id: sec.id, title: sec.title, isLive: sec.isLive, groups: groups)
            }
            out = es + out
        }
        return out
    }

    // MARK: EasySports（/api/easysports-slots と /api/easysports-vod-list）

    private struct ESSlots: Decodable {
        struct Slot: Decodable { let slot: Int?; let stripped: String?; let mediaId: String? }
        let slots: [Slot]?
    }
    private struct ESList: Decodable {
        struct Item: Decodable { let id: Int; let gameDate: String?; let title: String?; let playable: Bool?; let src: String?; let mediaId: String? }
        let items: [Item]
    }

    private static func getJSON<T: Decodable>(_ base: URL, _ path: String, _ type: T.Type) async -> T? {
        var req = URLRequest(url: base.appending(path: path))
        req.timeoutInterval = 30
        guard let (data, res) = try? await URLSession.shared.data(for: req),
              (res as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func easysports(base: URL) async -> [VODSection]? {
        async let slotsReq = getJSON(base, "api/easysports-slots", ESSlots.self)
        async let listReq = getJSON(base, "api/easysports-vod-list", ESList.self)
        let (slots, list) = await (slotsReq, listReq)
        guard let list else { return nil }
        var out: [VODSection] = []
        let lives = (slots?.slots ?? []).compactMap { s -> VODItem? in
            guard let mid = s.mediaId, let u = URL(string: "/easysports-vod/\(mid)/master.m3u8", relativeTo: base)?.absoluteURL else { return nil }
            return VODItem(id: "es-live-\(mid)", title: s.stripped ?? "EasySports slot \(s.slot ?? 0)", time: "", sub: "EasySports",
                           thumb: nil, kind: .direct(u), live: true)
        }
        if !lives.isEmpty {
            out.append(VODSection(id: "es-live", title: "EasySports ライブ", isLive: true, groups: [VODGroup(id: "es-live-g", title: "", items: lives)]))
        }
        // 日付の新しい順に、日ごとのグループにする（601 件ほどあるので LazyVStack で出す）
        let playable = list.items.filter { $0.playable == true && $0.mediaId != nil }
            .sorted { ($0.gameDate ?? "") > ($1.gameDate ?? "") }
        var byDay: [(String, [VODItem])] = []
        for x in playable {
            guard let src = x.src, let u = URL(string: src, relativeTo: base)?.absoluteURL else { continue }
            let day = x.gameDate ?? "日付なし"
            let item = VODItem(id: "es-\(x.id)", title: x.title ?? "", time: "", sub: "", thumb: nil, kind: .direct(u), live: false)
            if let i = byDay.firstIndex(where: { $0.0 == day }) { byDay[i].1.append(item) } else { byDay.append((day, [item])) }
        }
        if !byDay.isEmpty {
            out.append(VODSection(id: "es-vod", title: "EasySports VOD（\(playable.count)）", isLive: false,
                                  groups: byDay.map { VODGroup(id: "es-\($0.0)", title: $0.0, items: $0.1) }))
        }
        return out
    }

    // MARK: 解析

    private static func strip(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&rsaquo;", "›")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func first(_ pattern: String, in s: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > group, let r = Range(m.range(at: group), in: s) else { return nil }
        return String(s[r])
    }

    private static func unescape(_ s: String) -> String { s.replacingOccurrences(of: "&amp;", with: "&") }

    static func parse(_ html: String, base: URL) -> [VODSection] {
        var out: [VODSection] = []
        let sections = html.components(separatedBy: "<section class=\"").dropFirst()
        for (si, raw) in sections.enumerated() {
            let sec = raw.components(separatedBy: "</section>").first ?? raw
            let isLive = sec.hasPrefix("live-section")
            guard let h2 = first("<h2>(.*?)</h2>", in: sec) else { continue }
            let title = strip(h2.replacingOccurrences(of: "<span class=\"count\">", with: " <span>"))
            var groups: [VODGroup] = []
            if isLive {
                groups = [VODGroup(id: "s\(si)-g0", title: "", items: cards(in: sec, base: base, prefix: "s\(si)"))]
            } else {
                let rows = sec.components(separatedBy: "<div class=\"chrow\">").dropFirst()
                for (gi, row) in rows.enumerated() {
                    let name = strip(first("<h3>(.*?)</h3>", in: row) ?? "")
                    let items = cards(in: row, base: base, prefix: "s\(si)-g\(gi)")
                    if !items.isEmpty { groups.append(VODGroup(id: "s\(si)-g\(gi)", title: name, items: items)) }
                }
            }
            if groups.contains(where: { !$0.items.isEmpty }) {
                out.append(VODSection(id: "s\(si)", title: title, isLive: isLive, groups: groups))
            }
        }
        return out
    }

    private static func cards(in block: String, base: URL, prefix: String) -> [VODItem] {
        var items: [VODItem] = []
        let parts = block.components(separatedBy: "<div class=\"card").dropFirst()
        for (i, c) in parts.enumerated() {
            let live = c.hasPrefix(" alive")
            let title = strip(first("class=\"vid\">(.*?)</div>", in: c) ?? "")
            if title.isEmpty { continue }
            let time = strip(first("class=\"time\">(.*?)</div>", in: c) ?? "")
            let sub = strip(first("class=\"sub\">(.*?)</div>", in: c) ?? "")
            var thumb: URL?
            if let src = first("<img src=\"([^\"]+)\"", in: c) {
                let u = unescape(src)
                thumb = u.hasPrefix("http") ? URL(string: u) : URL(string: u, relativeTo: base)?.absoluteURL
            }
            let kind: VODItem.Kind
            if let u = first("<a href=\"(https?://[^\"]+\\.m3u8[^\"]*)\"", in: c), let url = URL(string: unescape(u)) {
                kind = .direct(url)
            } else if let id = first("(?:openGiantsPlay|copyGiantsUrl|openGiantsScheme)\\('([^']+)'", in: c) {
                kind = .giants(id)
            } else if let id = first("(?:copyEasysportsUrl|openEasysportsScheme)\\('([^']+)'", in: c) {
                kind = .easysports(id)
            } else if let u = first("data-url=\"([^\"]+\\.mpd[^\"]*)\"", in: c), let url = URL(string: unescape(u)) {
                kind = .mpd(url)
            } else if let u = first("data-url=\"(https?://[^\"]+\\.m3u8[^\"]*)\"", in: c), let url = URL(string: unescape(u)) {
                kind = .direct(url)
            } else { continue }
            items.append(VODItem(id: "\(prefix)-c\(i)", title: title, time: time, sub: sub, thumb: thumb, kind: kind, live: live))
        }
        return items
    }

    // MARK: URL の解決

    /// 再生に使う m3u8 の URL。GIANTS TV・EasySports はモニターに聞く
    static func resolve(_ item: VODItem) async throws -> URL {
        switch item.kind {
        case .direct(let u): return u
        case .mpd: throw VODError.unsupported("DASH（MPD）の配信は、このアプリではまだ再生できません")
        case .giants(let id): return try await ask("api/giantstv-play", [URLQueryItem(name: "contentId", value: id)])
        case .easysports(let id): return try await ask("api/easysports-play", [URLQueryItem(name: "mediaId", value: id)])
        }
    }

    private static func ask(_ path: String, _ q: [URLQueryItem]) async throws -> URL {
        guard let base = baseURL else { throw URLError(.badURL) }
        var c = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        c.queryItems = q
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: req)
        struct R: Decodable { let ok: Bool?; let url: String?; let error: String? }
        let r = try JSONDecoder().decode(R.self, from: data)
        guard r.ok == true, let s = r.url, let u = URL(string: s) else { throw VODError.unsupported("再生 URL を取得できませんでした（\(r.error ?? "不明")）") }
        return u
    }

    /// J-Sports は Referer がないと配信元に断られることがある
    static func headers(for url: URL) -> [String: String]? {
        guard let h = url.host else { return nil }
        if h.hasSuffix("jsports.co.jp") { return ["Referer": "https://www.jsports.co.jp/", "User-Agent": "Mozilla/5.0"] }
        return nil
    }
}

enum VODError: LocalizedError {
    case unsupported(String)
    var errorDescription: String? { if case .unsupported(let s) = self { return s } else { return nil } }
}

// MARK: - 一覧

struct VODMonitorView: View {
    @AppStorage("vodMonitorURL") private var monitorURL = Defaults.vodMonitorURL
    @State private var sections: [VODSection] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var filter = 0            // 0 ライブ, 1 オンデマンド, 2 韓国録画（TVH の DVR）
    @State private var playing: VODPlay?
    @State private var resolvingID: String?

    private struct VODPlay: Identifiable { let id = UUID(); let item: VODItem; let url: URL }

    private var shown: [VODSection] { filter == 2 ? [] : sections.filter { $0.isLive == (filter == 0) } }

    var body: some View {
        VStack(spacing: 0) {
            SegmentedPills(options: [0, 1, 2], label: { $0 == 0 ? "ライブ" : $0 == 1 ? "オンデマンド" : "韓国録画" }, selection: $filter)
                .padding(.horizontal, 12).padding(.bottom, 8)
            if filter == 2 {
                TVHRecordingsList()
            } else {
            if let errorText {
                Text(errorText).font(Theme.F.caption).foregroundStyle(Theme.C.rec)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 6)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if loading && sections.isEmpty { ProgressView().tint(Theme.C.accent).frame(maxWidth: .infinity).padding(.top, 30) }
                    ForEach(shown) { sec in
                        Text(sec.title).font(Theme.F.jp(15, .bold)).foregroundStyle(Theme.C.text)
                            .padding(.top, 10).padding(.horizontal, 4)
                        ForEach(sec.groups) { g in
                            if !g.title.isEmpty {
                                Text(g.title).font(Theme.F.jp(12, .medium)).foregroundStyle(Theme.C.text3)
                                    .padding(.horizontal, 4).padding(.top, 2)
                            }
                            ForEach(g.items) { item in
                                Button { Task { await play(item) } } label: { row(item) }.buttonStyle(.plain)
                            }
                        }
                    }
                    if !loading && shown.isEmpty && errorText == nil {
                        Text(filter == 0 ? "配信中のものはありません" : "オンデマンドはありません")
                            .font(Theme.F.jp(13)).foregroundStyle(Theme.C.text3)
                            .frame(maxWidth: .infinity).padding(.top, 30)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 16)
            }
            .refreshable { await load() }
            }
        }
        .task(id: monitorURL) { await load() }
        .fullScreenCover(item: $playing) { p in VODPlayerView(item: p.item, url: p.url) }
    }

    private func row(_ item: VODItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: item.thumb) { phase in
                if let img = phase.image { img.resizable().scaledToFill() } else { Theme.C.surface }
            }
            .frame(width: 136, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                if item.live {
                    Text("LIVE").font(Theme.F.mono(9, .bold)).foregroundStyle(Theme.C.onAccent)
                        .padding(.horizontal, 5).frame(height: 16).background(Theme.C.live, in: Capsule()).padding(4)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(Theme.F.jp(14, .bold)).foregroundStyle(Theme.C.text).lineLimit(2)
                if !item.time.isEmpty {
                    Text(item.time).font(Theme.F.caption).foregroundStyle(Theme.C.text3).lineLimit(1)
                }
                if !item.sub.isEmpty {
                    Text(item.sub).font(Theme.F.caption).foregroundStyle(Theme.C.text4).lineLimit(1)
                }
                if case .mpd = item.kind { TagView(text: "DASH（未対応）") }
                if resolvingID == item.id { ProgressView().controlSize(.small).tint(Theme.C.accent) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.C.row, in: RoundedRectangle(cornerRadius: Theme.R.card))
    }

    private func play(_ item: VODItem) async {
        resolvingID = item.id
        defer { resolvingID = nil }
        do {
            let url = try await VODMonitor.resolve(item)
            errorText = nil
            DebugLog.log("vod", "再生 \(item.title) \(url.host ?? "")")
            playing = VODPlay(item: item, url: url)
        } catch {
            errorText = describeError(error)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            sections = try await VODMonitor.fetch()
            errorText = nil
            if filter == 0, sections.allSatisfy({ !$0.isLive }) { filter = 1 }
        } catch {
            errorText = "VOD Monitor に接続できません: \(describeError(error))"
        }
    }
}

// MARK: - 再生

struct VODPlayerView: View {
    let item: VODItem
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @StateObject private var hls = HLSPlayback()
    @EnvironmentObject private var radio: RadioPlayer

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VideoPlayerControls(player: hls.player)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(Color.black.opacity(0.5), in: Circle())
                    }
                    Text(item.title).font(Theme.F.jp(13, .bold)).foregroundStyle(.white).lineLimit(1)
                        .shadow(radius: 2)
                    Spacer()
                }
                switch hls.state {
                case .loading: ProgressView().tint(.white).padding(.leading, 12)
                case .failed(let m): Text(m).font(Theme.F.caption).foregroundStyle(Theme.C.rec).padding(.leading, 12)
                default: EmptyView()
                }
            }
            .padding(12)
        }
        .onAppear {
            radio.stop()
            hls.play(url: url, headers: VODMonitor.headers(for: url))
        }
        .onDisappear { hls.stop() }
    }
}

/// AVPlayer 標準の操作（シークバー・一時停止・倍速）を出す
private struct VideoPlayerControls: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.allowsPictureInPicturePlayback = true
        vc.view.backgroundColor = .clear
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}
