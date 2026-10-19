import SwiftUI

/// アーカイブを番組表の形で見る: 日付を選ぶと、その日の放送を局 × 時刻に並べる。
/// 1 日はテレビの区切りと同じ 5:00〜翌 5:00（JST）。
///
/// 名前には終わりの時刻が無いので、箱の高さは「同じ局の次の番組の開始まで」と
/// 「ファイルの大きさから見積もった長さ（約 16Mbps）」の短いほう。
struct UsenetGuideView: View {
    /// 局で絞る（アーカイブ画面の局メニュー）。nil = すべての局
    let station: String?
    let positions: [String: Double]
    let watched: Set<String>
    let onPlay: (UsenetEntry) -> Void

    @ObservedObject private var catalog = UsenetCatalog.shared
    /// 表示している日（その日の 5:00 JST）。nil = まだ決めていない（最新の放送の日にする）
    @State private var day: Date?
    @State private var columns: [Column] = []
    @State private var dayCount = 0

    struct Column: Identifiable {
        let station: String
        let entries: [UsenetEntry]
        var id: String { station }
    }

    private var ppm: CGFloat { Theme.guidePointsPerMinute }
    private var totalHeight: CGFloat { 24 * 60 * ppm }
    private static let dayStartHour = 5

    private static var jst: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    /// その時刻が属するテレビの 1 日の始まり（5:00）
    static func broadcastDay(_ d: Date) -> Date {
        let cal = jst
        let shifted = d.addingTimeInterval(-Double(dayStartHour) * 3600)
        return cal.startOfDay(for: shifted).addingTimeInterval(Double(dayStartHour) * 3600)
    }

    /// 一番古い日〜一番新しい日。entries は放送の新しい順で、日時の無いものは最後なので、両端から探せばすぐ見つかる
    private var range: ClosedRange<Date>? {
        guard let newest = catalog.entries.first(where: { $0.airDate != nil })?.airDate,
              let oldest = catalog.entries.last(where: { $0.airDate != nil })?.airDate else { return nil }
        return Self.broadcastDay(oldest)...Self.broadcastDay(newest)
    }

    var body: some View {
        VStack(spacing: 0) {
            dayBar.padding(.horizontal, 12).padding(.bottom, 8)
            if catalog.entries.isEmpty {
                Text("アーカイブの一覧がまだありません").font(Theme.F.meta).foregroundStyle(Theme.C.muted)
                    .frame(maxWidth: .infinity).padding(.top, 40)
                Spacer()
            } else if columns.isEmpty {
                Text(station == nil ? "この日の番組はありません" : "この日の \(station!) の番組はありません")
                    .font(Theme.F.meta).foregroundStyle(Theme.C.muted)
                    .frame(maxWidth: .infinity).padding(.top, 40)
                Spacer()
            } else {
                grid
            }
        }
        .task(id: "\(day?.timeIntervalSince1970 ?? 0)|\(station ?? "")|\(catalog.revision)") { await load() }
    }

    // MARK: - 日付

    private var dayBar: some View {
        HStack(spacing: 8) {
            CircleButton(systemName: "chevron.left", size: 36) { move(-1) }
                .accessibilityLabel("前の日")
                .disabled(day.map { d in range.map { d <= $0.lowerBound } ?? true } ?? true)
            DatePicker("日付", selection: Binding(
                get: { day ?? Date() },
                set: { day = Self.broadcastDay($0.addingTimeInterval(Double(Self.dayStartHour) * 3600 + 60)) }),
                       in: range ?? Date.distantPast...Date.distantFuture,
                       displayedComponents: .date)
                .labelsHidden()
                .environment(\.locale, Locale(identifier: "ja_JP"))
                .environment(\.timeZone, TimeZone(identifier: "Asia/Tokyo")!)
            CircleButton(systemName: "chevron.right", size: 36) { move(1) }
                .accessibilityLabel("次の日")
                .disabled(day.map { d in range.map { d >= $0.upperBound } ?? true } ?? true)
            Spacer(minLength: 4)
            Text("\(dayCount) 番組").font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text4)
            if let r = range, day != r.upperBound {
                Button("最新") { day = r.upperBound }
                    .font(Theme.F.jp(13, .bold)).foregroundStyle(Theme.C.accent)
            }
        }
    }

    private func move(_ delta: Int) {
        guard let d = day else { return }
        day = Self.jst.date(byAdding: .day, value: delta, to: d)
    }

    // MARK: - 読み込み

    /// その日の番組を局ごとに分ける（7 万件を舐めるので裏で）
    private func load() async {
        if day == nil {
            guard let newest = catalog.entries.first(where: { $0.airDate != nil })?.airDate else { columns = []; return }
            day = Self.broadcastDay(newest)       // これで task が呼び直される
            return
        }
        guard let start = day else { return }
        let end = start.addingTimeInterval(86_400)
        let all = catalog.entries
        let order = Dictionary(uniqueKeysWithValues: catalog.stations.enumerated().map { ($0.element.name, $0.offset) })
        let st = station
        let result: ([Column], Int) = await Task.detached(priority: .userInitiated) {
            var by: [String: [UsenetEntry]] = [:]
            var n = 0
            for e in all {
                guard let a = e.airDate, a >= start, a < end else { continue }
                if let st, e.station != st { continue }
                by[e.station.isEmpty ? "局不明" : e.station, default: []].append(e)
                n += 1
            }
            let cols = by.map { Column(station: $0.key, entries: $0.value.sorted { $0.airDate! < $1.airDate! }) }
                .sorted { (order[$0.station] ?? Int.max, $0.station) < (order[$1.station] ?? Int.max, $1.station) }
            return (cols, n)
        }.value
        if Task.isCancelled { return }
        columns = result.0
        dayCount = result.1
    }

    // MARK: - グリッド

    private var firstHourID: String? {
        guard let start = day, let first = columns.compactMap({ $0.entries.first?.airDate }).min() else { return nil }
        let hour = Int(first.timeIntervalSince(start) / 3600)
        return "h\(max(hour - 1, 0))"
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        HStack(alignment: .top, spacing: 0) {
                            timeColumn
                            ForEach(columns) { column($0) }
                        }
                        .frame(height: totalHeight)
                    } header: {
                        headerRow
                    }
                }
            }
            // その日の最初の番組の少し前から見せる（深夜帯から始まる日でも 5 時の空白を延々と見せない）
            .onChange(of: firstHourID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .top) }
            }
            .onAppear {
                if let id = firstHourID { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) } }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Theme.guideTimeColumnWidth, height: 40)
            ForEach(columns) { c in
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.station).font(Theme.F.jp(12, .bold)).foregroundStyle(Theme.C.text2).lineLimit(1)
                    Text("\(c.entries.count) 番組").font(Theme.F.mono(10)).foregroundStyle(Theme.C.text4)
                }
                .padding(.leading, 6)
                .frame(width: Theme.guideColumnWidth, height: 40, alignment: .leading)
                .clipped()
            }
        }
        .background(Theme.C.bg)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.C.divider) }
    }

    private var timeColumn: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { i in
                Text("\((i + Self.dayStartHour) % 24)")
                    .font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text4)
                    .frame(width: Theme.guideTimeColumnWidth, height: 60 * ppm, alignment: .top)
                    .id("h\(i)")
            }
        }
    }

    private func column(_ c: Column) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: Theme.guideColumnWidth, height: totalHeight)
            ForEach(Array(c.entries.enumerated()), id: \.element.id) { i, e in
                block(e, next: i + 1 < c.entries.count ? c.entries[i + 1].airDate : nil)
            }
        }
        .frame(width: Theme.guideColumnWidth, height: totalHeight, alignment: .topLeading)
        .clipped()
    }

    /// ファイルの大きさから見積もった長さ（分）。放送の TS（約 16Mbps）として。10 分〜6 時間
    private static func estimatedMinutes(_ bytes: Int64) -> Double {
        guard bytes > 0 else { return 60 }
        return min(max(Double(bytes) * 8 / 16_000_000 / 60, 10), 360)
    }

    private func block(_ e: UsenetEntry, next: Date?) -> some View {
        let start = day ?? Date()
        let air = e.airDate ?? start
        var minutes = Self.estimatedMinutes(e.bytes)
        if let next { minutes = min(minutes, max(next.timeIntervalSince(air) / 60, 1)) }
        minutes = min(minutes, start.addingTimeInterval(86_400).timeIntervalSince(air) / 60)
        let y = CGFloat(air.timeIntervalSince(start) / 60) * ppm
        let h = max(CGFloat(minutes) * ppm - 4, 14)
        let seen = watched.contains(e.id)
        let resume = positions[e.watchKey]

        return Button { onPlay(e) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(air.hm).font(Theme.F.mono(10, .medium)).foregroundStyle(Theme.C.text4)
                    if seen {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.C.text4)
                    } else if resume != nil {
                        Circle().fill(Theme.C.accent).frame(width: 6, height: 6)
                    }
                }
                Text(e.title).font(Theme.F.jp(11, .bold))
                    .foregroundStyle(seen ? Theme.C.text3 : Theme.C.text)
                    .lineLimit(max(Int((h - 16) / 14), 1))
            }
            .padding(6)
            .frame(width: Theme.guideColumnWidth - 6, height: h, alignment: .topLeading)
            .background(Theme.C.row, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(resume != nil && !seen ? Theme.C.accent.opacity(0.6) : Theme.C.border.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .offset(x: 3, y: y + 2)
        .accessibilityLabel("\(air.hm) \(e.title)")
    }
}
