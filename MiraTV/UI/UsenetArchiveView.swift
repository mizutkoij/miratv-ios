import SwiftUI

/// 録画タブの「アーカイブ」: Usenet に上げたテレビの録画（VPS1 の nzb-dl）を探して再生する。
/// 一覧は端末に保存したものをすぐ出し、裏で新しい分だけ取り足す（UsenetCatalog）。
struct UsenetArchiveView: View {
    @ObservedObject private var catalog = UsenetCatalog.shared
    @EnvironmentObject private var session: PlaybackSession
    // 設定が変わったら作り直す（URL・キーを入れた直後に一覧を取りにいく）
    @AppStorage("nzbdlURL") private var nzbdlURL = Defaults.nzbdlURL
    @AppStorage("nzbdlKey") private var nzbdlKey = ""

    @State private var query = ""
    @State private var station: String?
    @State private var onlyResume = false
    @State private var results: [UsenetEntry] = []
    @State private var shownLimit = 100
    // 行ごとに UserDefaults を読むと押す・スクロールのたびに重いので、まとめて 1 回だけ読む
    @State private var exts: [String: String] = [:]
    @State private var positions: [String: Double] = [:]
    @FocusState private var searchFocused: Bool

    private static let pageSize = 100

    private var configured: Bool { Servers.nzbdl != nil }

    private var filterKey: String {
        "\(query)|\(station ?? "")|\(onlyResume)|\(catalog.revision)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if configured || !catalog.entries.isEmpty {
                searchBar.padding(.horizontal, 12).padding(.bottom, 8)
                filterRow.padding(.horizontal, 12).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    content
                }
                .padding(.horizontal, 12).padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await catalog.refresh() }
        }
        .task(id: "\(nzbdlURL)|\(nzbdlKey)") {
            await catalog.loadIfNeeded()
            // 一覧が古ければ新しい分だけ取り足す（新しい順に 1 ページ見るだけなので軽い）
            let stale = catalog.lastSync.map { Date().timeIntervalSince($0) > 15 * 60 } ?? true
            if configured && stale { await catalog.refresh() }
        }
        .task(id: filterKey) { reloadSnapshots(); await applyFilter() }
        .onAppear { reloadSnapshots() }
    }

    private func reloadSnapshots() {
        exts = catalog.extSnapshot()
        positions = WatchPositions.snapshot
    }

    // MARK: - 探す

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.C.text4)
            TextField("番組名・局・日付（例: 阪神 0527）", text: $query)
                .font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.C.text4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("検索をクリア")
            }
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(Theme.C.surface, in: RoundedRectangle(cornerRadius: Theme.R.button))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.button).stroke(Theme.C.border))
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            Menu {
                Button("すべての局") { station = nil }
                Divider()
                ForEach(catalog.stations) { s in
                    Button("\(s.name)（\(s.count)）") { station = s.name }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(station ?? "すべての局").lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .font(Theme.F.jp(13, station == nil ? .medium : .bold))
                .foregroundStyle(station == nil ? Theme.C.text2 : Theme.C.onAccent)
                .padding(.horizontal, 12).frame(minHeight: 32)
                .background(station == nil ? Theme.C.surface : Theme.C.accent, in: Capsule())
                .overlay(Capsule().stroke(station == nil ? Theme.C.border : Color.clear))
            }
            ChipView(label: "続きから", selected: onlyResume) { onlyResume.toggle() }
            Spacer(minLength: 4)
            Text("\(results.count) 件").font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text4)
        }
    }

    /// 絞り込みは 7 万件を舐めるので裏で。打っている間は少し待ってからやる
    private func applyFilter() async {
        if !query.isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
        }
        let all = catalog.entries
        let q = query, st = station
        var r = await Task.detached(priority: .userInitiated) {
            UsenetCatalog.filter(all, query: q, station: st)
        }.value
        if Task.isCancelled { return }
        if onlyResume {
            let keys = Set(positions.keys)
            r = r.filter { keys.contains($0.watchKey) }
        }
        results = r
        shownLimit = Self.pageSize
    }

    // MARK: - 一覧

    @ViewBuilder private var content: some View {
        if !configured && catalog.entries.isEmpty {
            setupHint
        } else if results.isEmpty {
            if catalog.syncing && catalog.entries.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().tint(Theme.C.text3)
                    Text("初回は一覧をまとめて取得します（約 7 万件、数十秒〜数分）")
                        .font(Theme.F.caption).foregroundStyle(Theme.C.text4).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.top, 40)
            } else {
                empty(catalog.entries.isEmpty ? "アーカイブはまだありません" : "見つかりませんでした")
            }
        } else {
            ForEach(results.prefix(shownLimit)) { e in
                Button { play(e) } label: { row(e) }
                    .buttonStyle(.plain)
            }
            if results.count > shownLimit {
                Button { shownLimit += Self.pageSize } label: {
                    Text("もっと表示（\(shownLimit)/\(results.count)）")
                        .font(Theme.F.jp(13, .medium)).foregroundStyle(Theme.C.text2)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func play(_ e: UsenetEntry) {
        searchFocused = false
        guard let client = Servers.nzbdl else { return }
        session.playUsenet(e, client: client)
    }

    private func row(_ e: UsenetEntry) -> some View {
        let ext = exts[e.id]
        let locked = ext == "7z" || ext == "rar" || ext == "zip"
        let resume = positions[e.watchKey]
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.airDate.map(Self.dayText) ?? "日時不明").font(Theme.F.jp(11)).foregroundStyle(Theme.C.text4)
                Text(e.airDate?.hm ?? "--:--").font(Theme.F.mono(15)).foregroundStyle(Theme.C.text)
            }
            .frame(width: 68, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if !e.station.isEmpty {
                    Text(e.station).font(Theme.F.caption).foregroundStyle(Theme.C.text3).lineLimit(1)
                }
                Text(e.title).font(Theme.F.jp(14, .bold))
                    .foregroundStyle(locked ? Theme.C.muted : Theme.C.text).lineLimit(2)
                HStack(spacing: 6) {
                    if let ext { TagView(text: locked ? "暗号化" : ext.uppercased()) }
                    ForEach(e.flags.prefix(4), id: \.self) { TagView(text: $0) }
                    if e.bytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: e.bytes, countStyle: .file))
                            .font(Theme.F.mono(11)).foregroundStyle(Theme.C.text4)
                    }
                    if let resume {
                        Text("続き \(Self.clock(resume))").font(Theme.F.jp(11, .bold)).foregroundStyle(Theme.C.accent)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.C.row, in: RoundedRectangle(cornerRadius: Theme.R.card))
        .contentShape(RoundedRectangle(cornerRadius: Theme.R.card))
    }

    private var setupHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Usenet のアーカイブ").font(Theme.F.section).foregroundStyle(Theme.C.text)
            Text("設定タブの「nzb-dl（Usenet のアーカイブ）」に、VPS1 の nzb-dl の URL（Tailscale のアドレス、例 http://100.x.x.x:8083）と API キーを入れると、ここに一覧が出ます。")
                .font(Theme.F.jp(13)).foregroundStyle(Theme.C.text3)
            Text("再生は nzb-dl が Usenet から必要な部分だけを取って返すので、ダウンロードを待たずにシークできます。")
                .font(Theme.F.caption).foregroundStyle(Theme.C.text4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.C.row, in: RoundedRectangle(cornerRadius: Theme.R.card))
        .padding(.top, 12)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(Theme.F.meta).foregroundStyle(Theme.C.muted)
            .frame(maxWidth: .infinity).padding(.top, 40)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yy/M/d(E)"
        return f
    }()

    private static func dayText(_ d: Date) -> String { dayFormatter.string(from: d) }

    private static func clock(_ seconds: Double) -> String {
        let t = Int(seconds)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}
