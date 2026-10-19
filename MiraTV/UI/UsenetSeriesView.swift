import SwiftUI

/// アーカイブのシリーズ一覧: 同じ番組の別の回をまとめて、最新の回が新しい順に並べる。
/// 押すとその番組の回の一覧（UsenetSeriesSheet）。
struct UsenetSeriesView: View {
    let query: String
    let station: String?
    let positions: [String: Double]
    let watched: Set<String>
    let onPlay: (UsenetEntry) -> Void

    @ObservedObject private var catalog = UsenetCatalog.shared
    @State private var results: [UsenetSeries] = []
    @State private var shownLimit = 60
    @State private var opened: UsenetSeries?

    private static let pageSize = 60

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                HStack {
                    Text("\(results.count) シリーズ").font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text4)
                    Spacer()
                }
                .padding(.horizontal, 4)
                if results.isEmpty {
                    Text(catalog.series.isEmpty ? "まとめられる番組はまだありません" : "見つかりませんでした")
                        .font(Theme.F.meta).foregroundStyle(Theme.C.muted)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
                ForEach(results.prefix(shownLimit)) { s in
                    Button { opened = s } label: { row(s) }.buttonStyle(.plain)
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
            .padding(.horizontal, 12).padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await catalog.refresh() }
        .task(id: "\(query)|\(station ?? "")|\(catalog.revision)") { await applyFilter() }
        .sheet(item: $opened) { s in
            UsenetSeriesSheet(series: s, positions: positions, watched: watched) { e in
                opened = nil
                onPlay(e)
            }
        }
    }

    private func applyFilter() async {
        if !query.isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
        }
        let all = catalog.series, members = catalog.seriesMembers
        let q = query, st = station
        let r = await Task.detached(priority: .userInitiated) {
            UsenetCatalog.filterSeries(all, query: q, station: st, members: members)
        }.value
        if Task.isCancelled { return }
        results = r
        shownLimit = Self.pageSize
    }

    private func row(_ s: UsenetSeries) -> some View {
        let list = catalog.members(of: s.key)
        let seen = list.filter { watched.contains($0.id) }.count
        let inProgress = list.contains { positions[$0.watchKey] != nil }
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.title).font(Theme.F.jp(15, .bold)).foregroundStyle(Theme.C.text).lineLimit(2)
                Text(s.stationCount > 1 ? "\(s.station) ほか \(s.stationCount - 1) 局" : s.station)
                    .font(Theme.F.caption).foregroundStyle(Theme.C.text3).lineLimit(1)
                HStack(spacing: 8) {
                    Text("\(s.count) 回").font(Theme.F.mono(11, .medium)).foregroundStyle(Theme.C.text3)
                    Text(Self.period(s)).font(Theme.F.mono(11)).foregroundStyle(Theme.C.text4)
                    if seen > 0 {
                        Text("見た \(seen)").font(Theme.F.jp(11, .medium)).foregroundStyle(Theme.C.text4)
                    }
                    if inProgress {
                        Text("途中あり").font(Theme.F.jp(11, .bold)).foregroundStyle(Theme.C.accent)
                    }
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.C.text4)
        }
        .padding(12)
        .background(Theme.C.row, in: RoundedRectangle(cornerRadius: Theme.R.card))
        .contentShape(RoundedRectangle(cornerRadius: Theme.R.card))
    }

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yy/M/d"
        return f
    }()

    static func period(_ s: UsenetSeries) -> String {
        guard let a = s.first, let b = s.latest else { return "" }
        let x = shortDate.string(from: a), y = shortDate.string(from: b)
        return x == y ? x : "\(x)〜\(y)"
    }
}

/// 1 つのシリーズの回の一覧。「続きを見る」で、途中の回か、見た回の次の回から
struct UsenetSeriesSheet: View {
    let series: UsenetSeries
    let positions: [String: Double]
    let onPlay: (UsenetEntry) -> Void

    @ObservedObject private var catalog = UsenetCatalog.shared
    @AppStorage("nzbSeriesNewestFirst") private var newestFirst = false
    /// この画面で「見た」を付け外ししたら反映する（親から受け取った分はその時点のもの）
    @State private var watched: Set<String>
    @Environment(\.dismiss) private var dismiss

    init(series: UsenetSeries, positions: [String: Double], watched: Set<String>, onPlay: @escaping (UsenetEntry) -> Void) {
        self.series = series
        self.positions = positions
        self.onPlay = onPlay
        _watched = State(initialValue: watched)
    }

    private var members: [UsenetEntry] { catalog.members(of: series.key) }

    /// 次に見る回: 途中まで見たもの（一番新しい放送）→ 最後に見た回の次 → 最初の回
    private var nextUp: UsenetEntry? {
        let list = members
        if let partial = list.last(where: { positions[$0.watchKey] != nil }) { return partial }
        if let i = list.lastIndex(where: { watched.contains($0.id) }) {
            return i + 1 < list.count ? list[i + 1] : nil
        }
        return list.first
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.C.bg.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        header.padding(.bottom, 8)
                        ForEach(newestFirst ? Array(members.reversed()) : members) { e in
                            Button { onPlay(e) } label: { row(e) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if watched.contains(e.id) {
                                        Button { UsenetWatched.unmark(e.id); watched.remove(e.id) } label: {
                                            Label("見ていないことにする", systemImage: "arrow.uturn.backward")
                                        }
                                    } else {
                                        Button { UsenetWatched.mark(e.id); watched.insert(e.id) } label: {
                                            Label("見たことにする", systemImage: "checkmark")
                                        }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 24)
                }
            }
            .navigationTitle(series.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { newestFirst.toggle() } label: {
                        Label(newestFirst ? "新しい順" : "古い順", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(series.count) 回 · \(UsenetSeriesView.period(series))\(series.stationCount > 1 ? " · \(series.stationCount) 局" : "")")
                .font(Theme.F.caption).foregroundStyle(Theme.C.text3)
            if let next = nextUp {
                Button { onPlay(next) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(positions[next.watchKey] != nil ? "続きから見る" : (watched.isEmpty ? "最初の回から見る" : "次の回を見る"))
                                .font(Theme.F.jp(14, .bold))
                            Text("\(next.airDate.map(Self.dayText) ?? "") \(next.title)")
                                .font(Theme.F.caption).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.C.onAccent)
                    .padding(.horizontal, 14).frame(minHeight: 52)
                    .background(Theme.C.accent, in: RoundedRectangle(cornerRadius: Theme.R.button))
                }
                .buttonStyle(.plain)
            } else {
                Text("全部見ました").font(Theme.F.jp(13, .medium)).foregroundStyle(Theme.C.text3)
            }
            Text("見終わると、次の回へ自動で進みます。長押しで「見た」を付け外しできます。")
                .font(Theme.F.caption).foregroundStyle(Theme.C.text4)
        }
        .padding(.top, 8)
    }

    private func row(_ e: UsenetEntry) -> some View {
        let seen = watched.contains(e.id)
        let resume = positions[e.watchKey]
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.airDate.map(Self.dayText) ?? "日時不明").font(Theme.F.jp(11)).foregroundStyle(Theme.C.text4)
                Text(e.airDate?.hm ?? "--:--").font(Theme.F.mono(15)).foregroundStyle(seen ? Theme.C.text3 : Theme.C.text)
            }
            .frame(width: 68, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(e.title).font(Theme.F.jp(14, .bold)).foregroundStyle(seen ? Theme.C.text3 : Theme.C.text).lineLimit(3)
                HStack(spacing: 6) {
                    if series.stationCount > 1 && !e.station.isEmpty {
                        Text(e.station).font(Theme.F.caption).foregroundStyle(Theme.C.text4).lineLimit(1)
                    }
                    if seen {
                        Label("見た", systemImage: "checkmark").font(Theme.F.jp(11, .medium)).foregroundStyle(Theme.C.text4)
                    } else if let resume {
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
