import SwiftUI

/// DESIGN.md「チャンネル一覧（Main）」の実装
struct ChannelListView: View {
    @AppStorage("mirakurunURL") private var serverURL = Defaults.mirakurunURL
    @EnvironmentObject private var epg: EPGStore

    @State private var services: [MirakurunService] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var band = "GR"
    @State private var playing: MirakurunService?
    @State private var now = Date()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private static let bands = ["GR", "BS", "CS"]

    @AppStorage("showInactiveChannels") private var showInactive = false
    @AppStorage("epgstationURL") private var epgURL = Defaults.epgstationURL

    private var client: MirakurunClient? { MirakurunClient(serverURL) }

    /// SKY は CS として扱う
    private func bandOf(_ s: MirakurunService) -> String {
        switch s.channel?.type {
        case "GR": "GR"
        case "BS": "BS"
        case "CS", "SKY": "CS"
        default: "他"
        }
    }

    private func items(in band: String) -> [MirakurunService] {
        let showAll = showInactive
        return services
            .filter { $0.isTV && bandOf($0) == band && (showAll || epg.isActive($0)) }
            .sorted { ($0.remoteControlKeyId ?? 99, $0.serviceId) < ($1.remoteControlKeyId ?? 99, $1.serviceId) }
    }

    private func label(_ band: String) -> String {
        switch band {
        case "GR": "地上波"
        default: band
        }
    }

    private var statusText: String {
        if let errorText { return errorText }
        if loading && services.isEmpty { return "接続中…" }
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
                    CircleButton(systemName: "arrow.clockwise") { Task { await load() } }
                }
                SegmentedPills(options: Self.bands, label: label, selection: $band)
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
                .refreshable { await load() }
            }
        }
        .task(id: serverURL) { await load() }
        .task(id: epgURL) { await epg.refreshOverview(es: Servers.epgstation, force: true) }
        .onReceive(ticker) { t in
            now = t
            Task { await epg.refreshOverview(es: Servers.epgstation) }
        }
        .fullScreenCover(item: $playing) { s in
            if let client {
                PlayerView(service: s, services: items(in: bandOf(s)), client: client)
            }
        }
    }

    private func row(_ s: MirakurunService) -> some View {
        let p = epg.current(s, at: now)
        let next = epg.upcoming(s, at: now, limit: 1).first
        return Button { playing = s } label: {
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
        .task(id: epg.overviewFailed) {
            // EPGStation の概要が取れなかったときだけ、局ごとに Mirakurun から取る（重いのでフォールバック）
            if epg.overviewFailed, let client { await epg.loadViaMirakurun(s, client: client) }
        }
    }

    private func load() async {
        guard let client else { errorText = "URL が不正です"; return }
        if services.isEmpty, let c = MirakurunClient.cachedServices() { services = c }   // 前回の局一覧を先に出す
        loading = services.isEmpty
        defer { loading = false }
        do {
            services = try await client.services()
            errorText = nil
            await epg.refreshOverview(es: Servers.epgstation, force: true)
        } catch {
            if services.isEmpty { errorText = "取得に失敗: \(describeError(error))" }
        }
    }
}
