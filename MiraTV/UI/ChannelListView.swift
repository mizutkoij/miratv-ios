import SwiftUI

/// DESIGN.md「チャンネル一覧（Main）」の実装
struct ChannelListView: View {
    @AppStorage("mirakurunURL") private var url1 = Defaults.mirakurunURL
    @AppStorage("mirakurun2URL") private var url2 = Defaults.mirakurun2URL
    @AppStorage("mirakurunActive") private var activeServer = 0
    private var hasSecond: Bool { !url2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var onSecond: Bool { hasSecond && activeServer == 1 }
    /// 見ているほうの Mirakurun。切り替えると局一覧を取り直す
    private var serverURL: String { onSecond ? url2 : url1 }
    @EnvironmentObject private var epg: EPGStore
    @EnvironmentObject private var session: PlaybackSession

    @State private var services: [MirakurunService] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var band = "GR"
    @State private var now = Date()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private static let bands = ["GR", "BS", "CS"]
    /// 2 台目で、これ以内に始まる予定があれば「配信あり」として出す
    private static let upcomingHours = 3.0

    @AppStorage("showInactiveChannels") private var showInactive = false
    @AppStorage("epgstationURL") private var epgURL = Defaults.epgstationURL

    private var client: MirakurunClient? { MirakurunClient(serverURL) }

    /// 2 台目の Mirakurun は、放送波の枠（GR/BS/CS）に配信・海外の局を割り当てているだけなので、局名で種類を分ける。
    /// 例: 地上波枠 = ABEMA、BS 枠 = MLB・各種配信、CS 枠 = 韓国の放送・DAZN
    private static let secondBands = ["ABEMA", "MLB", "配信", "DAZN", "韓国", "他"]

    private func secondBandOf(_ s: MirakurunService) -> String {
        let n = s.name
        if n.hasPrefix("ABEMA") || s.channel?.type == "GR" { return "ABEMA" }
        if n.hasPrefix("MLB") { return "MLB" }
        if n.hasPrefix("DAZN") { return "DAZN" }
        if n.hasPrefix("QAM/") || n.hasPrefix("{") { return "他" }
        if s.channel?.type == "CS" { return "韓国" }
        return "配信"   // BS 枠: FOD / U-NEXT / Hulu / J-Sports / EasySports / 虎テレ / GIANTS TV / NHK World など
    }

    private var bands: [String] { onSecond ? Self.secondBands : Self.bands }

    /// SKY は CS として扱う
    private func bandOf(_ s: MirakurunService) -> String {
        if onSecond { return secondBandOf(s) }
        return switch s.channel?.type {
        case "GR": "GR"
        case "BS": "BS"
        case "CS", "SKY": "CS"
        default: "他"
        }
    }

    private func items(in band: String) -> [MirakurunService] {
        let showAll = showInactive
        return services
            // EPGStation の概要は 1 台目の局だけ。2 台目は EPGStation に載らない局が多いので全部出す
            .filter { $0.isTV && bandOf($0) == band && (showAll || onSecond || epg.isActive($0)) }
            // 2 台目: 放送・配信がない局（数時間以内の予定もない局）は隠す。設定の「放送のない局も表示」で全部出せる
            .filter { !(onSecond && !showAll && epg.hasNoBroadcast($0, at: now, within: Self.upcomingHours)) }
            .sorted { ($0.remoteControlKeyId ?? 99, $0.serviceId) < ($1.remoteControlKeyId ?? 99, $1.serviceId) }
    }

    private func label(_ band: String) -> String {
        switch band {
        case "GR": "地上波"
        default: band
        }
    }

    /// 前回の一覧を出したまま、取り直しに失敗した
    @State private var refreshFailed = false
    /// いま持っている一覧がどのサーバーのものか（接続先を変えたら前のサーバーの一覧を残さない）
    @State private var servicesFrom: String?

    private var statusText: String {
        if let errorText { return errorText }
        if loading && services.isEmpty { return "接続中…" }
        if refreshFailed { return "Mirakurun · 前回の一覧を表示中（更新できませんでした）" }
        let host = client?.baseURL.host ?? "-"
        let hidden = services.filter { $0.isTV && bandOf($0) == band }.count - items(in: band).count
        let hiddenText = hidden > 0 ? "（放送なし \(hidden) 局は非表示）" : ""
        return "Mirakurun · \(host) · \(items(in: band).count) 局\(hiddenText)"
    }

    var body: some View {
        ZStack {
            Theme.C.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "チャンネル",
                             status: StatusLine(text: statusText,
                                                color: errorText == nil ? Theme.C.live : Theme.C.rec)) {
                    CircleButton(systemName: "arrow.clockwise") { Task { await load(manual: true) } }
                }
                if hasSecond {
                    SegmentedPills(options: [0, 1], label: { $0 == 0 ? "Mirakurun 1" : "Mirakurun 2" }, selection: $activeServer)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
                SegmentedPills(options: bands, label: label, selection: $band)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)

                if services.isEmpty && loading {
                    ProgressView().tint(Theme.C.accent).frame(maxWidth: .infinity).padding(.top, 40)
                }
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(items(in: band)) { s in row(s) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
                .refreshable { await load(manual: true) }
            }
        }
        .task(id: serverURL) { await load() }
        // 2 台目は、隠す局を決めるために全局の番組表を先に取る（最初の 1 回で全局ぶんが届き、残りは覚えた分を使う）
        .task(id: onSecond ? services.count : -1) {
            guard onSecond, let client else { return }
            for s in services where s.isTV { await epg.loadViaMirakurun(s, client: client) }
        }
        .onChange(of: onSecond) { _, _ in if !bands.contains(band) { band = bands[0] } }
        .task(id: epgURL) { await epg.refreshOverview(es: Servers.epgstation, force: true) }
        .onReceive(ticker) { t in
            now = t
            Task { await epg.refreshOverview(es: Servers.epgstation) }
        }
    }

    private func row(_ s: MirakurunService) -> some View {
        let p = epg.current(s, at: now)
        let next = epg.upcoming(s, at: now, limit: 1).first
        return Button {
            if let client { session.playLive(s, services: items(in: bandOf(s)), client: client) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                    LogoTile(url: client?.logoURL(for: s), size: Theme.Logo.list)
                    Text(s.remoteControlKeyId.map { "\($0)ch" } ?? "–")
                        .font(Theme.F.mono(12)).foregroundStyle(Theme.C.text2)
                }
                .frame(width: 64)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(s.name).font(Theme.F.meta).foregroundStyle(Theme.C.text3).lineLimit(1)
                        Spacer(minLength: 4)
                        if let p { Text(p.timeRange).font(Theme.F.mono(11, .medium)).foregroundStyle(Theme.C.text4) }
                    }
                    Text(p?.title ?? " ")
                        .font(Theme.F.rowTitle).foregroundStyle(Theme.C.text).lineLimit(1)
                    ProgressBar(progress: p?.progress(at: now) ?? 0)
                    Text(next.map { "次 \($0.start.hm) \($0.title)" } ?? " ")
                        .font(Theme.F.caption).foregroundStyle(Theme.C.text4).lineLimit(1)
                }
            }
            .rowCard()
        }
        .buttonStyle(.plain)
        .task(id: epg.overviewFailed || onSecond) {
            // EPGStation の概要が取れなかったとき、または 2 台目のときだけ、局ごとに Mirakurun から取る（重いので表示中の行だけ）
            if epg.overviewFailed || onSecond, let client { await epg.loadViaMirakurun(s, client: client) }
        }
    }

    /// 前回の一覧があればすぐ出して、裏で取り直す。番組の概要は epgURL の task が取るので、
    /// 起動時はここで取らない（以前は起動のたびに 2 回取っていた）。手動の更新のときだけ一緒に取り直す
    private func load(manual: Bool = false) async {
        guard let client else { errorText = "URL が不正です"; return }
        if servicesFrom != serverURL {
            services = client.cachedServices() ?? []
            servicesFrom = serverURL
            refreshFailed = false
        }
        epg.restoreFromDisk()
        loading = true
        defer { loading = false }
        do {
            services = try await client.services()
            errorText = nil
            refreshFailed = false
            if manual { await epg.refreshOverview(es: Servers.epgstation, force: true) }
        } catch {
            if services.isEmpty {
                errorText = "取得に失敗: \(describeError(error))"
            } else {
                refreshFailed = true
                DebugLog.log("net", "局一覧の更新に失敗（前回の一覧で続行）: \(describeError(error))")
            }
        }
    }
}
