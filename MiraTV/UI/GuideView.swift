import SwiftUI

/// 番組表で番組をタップしたときに詳細シートへ渡すもの
struct GuideSelection: Identifiable {
    let program: Program
    let channel: ESChannel
    var id: Int64 { program.id }
}

/// DESIGN.md「番組表（Guide）」の実装。1 分 = 2pt、列幅 116pt、時刻列 40pt。
/// データは EPGStation の `/api/schedules`（放送波と日付ごとに 24 時間ぶん）
struct GuideView: View {
    @AppStorage("epgstationURL") private var epgURL = Defaults.epgstationURL
    @EnvironmentObject private var reserves: ReserveStore

    @State private var band = "GR"
    @State private var dayOffset = 0
    @State private var columns: [ESSchedule] = []
    @State private var cache: [String: [ESSchedule]] = [:]
    @State private var loading = false
    @State private var errorText: String?
    @State private var selected: GuideSelection?
    @State private var now = Date()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private static let bands = ["GR", "BS", "CS"]
    private var ppm: CGFloat { Theme.guidePointsPerMinute }
    private var totalHeight: CGFloat { 24 * 60 * ppm }

    private static var jst: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    /// 今日から 7 日分（今日 + 6 日）
    private static let dayCount = 7

    /// 1 日は 0:00〜24:00（JST）。日をまたぐ番組は、前の日では下端・次の日では上端で切れて両方に出る
    private func dayStart(_ offset: Int) -> Date {
        let cal = Self.jst
        return cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date()))!
    }

    private var windowStart: Date { dayStart(dayOffset) }

    private func cacheKey(_ offset: Int) -> String { "\(band)-\(Int(dayStart(offset).timeIntervalSince1970))" }

    private func bandLabel(_ b: String) -> String { b == "GR" ? "地上波" : b }

    private func dayLabel(_ offset: Int) -> String {
        if offset == 0 { return "今日" }
        if offset == 1 { return "明日" }
        let d = Self.jst.date(byAdding: .day, value: offset, to: Self.jst.startOfDay(for: Date()))!
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "M/d(E)"
        return f.string(from: d)
    }

    var body: some View {
        ZStack {
            Theme.C.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "番組表",
                             status: errorText.map { StatusLine(text: $0, color: Theme.C.rec) }) {
                    Menu {
                        Picker("放送波", selection: $band) {
                            ForEach(Self.bands, id: \.self) { Text(bandLabel($0)).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(bandLabel(band)).font(Theme.F.jp(14, .bold))
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(Theme.C.text)
                        .padding(.horizontal, 14).frame(height: 40)
                        .background(Theme.C.surface, in: Capsule())
                        .overlay(Capsule().stroke(Theme.C.border))
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(0..<Self.dayCount, id: \.self) { i in
                            ChipView(label: dayLabel(i), selected: i == dayOffset) { dayOffset = i }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.bottom, 8)

                if loading && columns.isEmpty {
                    ProgressView().tint(Theme.C.accent).frame(maxWidth: .infinity).padding(.top, 40)
                }
                grid
            }
        }
        .task(id: "\(band)-\(dayOffset)-\(epgURL)") {
            await load()
            await reserves.refresh()
            await prefetchOtherDays()      // 予約の印を先に出してから、残りの日を裏で取る
        }
        .onReceive(ticker) { now = $0 }
        .sheet(item: $selected) { sel in
            ProgramDetailSheet(selection: sel)
                .environmentObject(reserves)
        }
    }

    // MARK: - グリッド

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ZStack(alignment: .topLeading) {
                            HStack(alignment: .top, spacing: 0) {
                                timeColumn
                                ForEach(columns, id: \.channel.id) { s in column(s) }
                            }
                            .frame(height: totalHeight)
                            nowLine
                            Color.clear.frame(width: 1, height: 1).id("now").offset(y: max(nowY - 120, 0))
                        }
                    } header: {
                        headerRow
                    }
                }
            }
            .onChange(of: columns.count) { _, _ in
                if dayOffset == 0 { proxy.scrollTo("now", anchor: .top) }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Theme.guideTimeColumnWidth, height: 44)
            ForEach(columns, id: \.channel.id) { s in
                HStack(spacing: 6) {
                    LogoTile(url: Servers.epgstation?.logoURL(channelId: s.channel.id), size: Theme.Logo.guide)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(s.channel.remoteControlKeyId.map(String.init) ?? "")
                            .font(Theme.F.mono(12)).foregroundStyle(Theme.C.accent)
                        Text(s.channel.name).font(Theme.F.jp(11, .medium)).foregroundStyle(Theme.C.text2).lineLimit(1)
                    }
                }
                .padding(.leading, 4)
                .frame(width: Theme.guideColumnWidth, height: 44, alignment: .leading)
                .clipped()
            }
        }
        .background(Theme.C.bg)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.C.divider) }
    }

    private var timeColumn: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { i in
                Text("\(i)")
                    .font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text4)
                    .frame(width: Theme.guideTimeColumnWidth, height: 60 * ppm, alignment: .top)
            }
        }
    }

    private func column(_ s: ESSchedule) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: Theme.guideColumnWidth, height: totalHeight)
            ForEach(visiblePrograms(s)) { p in block(p, channel: s.channel) }
        }
        .frame(width: Theme.guideColumnWidth, height: totalHeight, alignment: .topLeading)
        .clipped()
    }

    /// その日（0:00〜24:00）にかかる番組だけ。範囲外の番組を描くと、上端に潰れた箱が重なったり、
    /// 列の下にはみ出したりする。重複（同じ番組 ID）も除く
    private func visiblePrograms(_ s: ESSchedule) -> [ESProgram] {
        let from = Int64(windowStart.timeIntervalSince1970 * 1000)
        let to = from + 86_400_000
        var seen = Set<Int64>()
        return s.programs
            .filter { $0.endAt > from && $0.startAt < to && $0.endAt > $0.startAt }
            .sorted { $0.startAt < $1.startAt }
            .filter { seen.insert($0.id).inserted }
    }

    private func block(_ esProgram: ESProgram, channel: ESChannel) -> some View {
        let p = Program(es: esProgram)
        let start = max(p.start, windowStart)
        let end = min(p.end, windowStart.addingTimeInterval(86400))
        let minutes = max(end.timeIntervalSince(start) / 60, 1)
        let y = CGFloat(start.timeIntervalSince(windowStart) / 60) * ppm
        let h = max(CGFloat(minutes) * ppm - 4, 14)
        let onAir = p.isOnAir(at: now)
        let reserve = reserves.reserve(forProgram: p.id)

        return Button { selected = GuideSelection(program: p, channel: channel) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.start.hm).font(Theme.F.mono(10, .medium)).foregroundStyle(Theme.C.text4)
                Text(p.title).font(Theme.F.jp(11, .bold)).foregroundStyle(Theme.C.text)
                    .lineLimit(max(Int((h - 16) / 14), 1))
            }
            .padding(6)
            .frame(width: Theme.guideColumnWidth - 6, height: h, alignment: .topLeading)
            .background(onAir ? Color(hex: 0x221E14) : Theme.C.row, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(onAir ? Color(hex: 0x4A3B1A) : Theme.C.border.opacity(0.5)))
            .overlay(alignment: .topTrailing) {
                if let reserve {
                    Text(reserve.isConflict == true ? "競合" : "録")
                        .font(Theme.F.jp(9, .bold))
                        .foregroundStyle(Theme.C.onRec)
                        .padding(.horizontal, 5).frame(height: 16)
                        .background(reserve.isConflict == true ? Theme.C.warn : Theme.C.rec, in: Capsule())
                        .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
        .offset(x: 3, y: y + 2)
    }

    private var nowY: CGFloat { CGFloat(now.timeIntervalSince(windowStart) / 60) * ppm }

    @ViewBuilder private var nowLine: some View {
        if dayOffset == 0, nowY >= 0, nowY <= totalHeight {
            HStack(spacing: 0) {
                Text(now.hm).font(Theme.F.mono(10)).foregroundStyle(Theme.C.onAccent)
                    .padding(.horizontal, 3).background(Theme.C.accent, in: RoundedRectangle(cornerRadius: 3))
                Rectangle().fill(Theme.C.accent).frame(height: 2)
            }
            .frame(width: Theme.guideTimeColumnWidth + Theme.guideColumnWidth * CGFloat(columns.count))
            .offset(y: nowY - 1)
            .allowsHitTesting(false)
        }
    }

    // MARK: - 読み込み

    /// その日（0:00〜24:00）の番組表を取って、メモリと端末に保存する
    private func fetch(_ offset: Int, es: EPGStationClient) async throws -> [ESSchedule] {
        let start = dayStart(offset)
        let key = cacheKey(offset)
        let list = Self.sorted(try await es.schedules(from: start, to: start.addingTimeInterval(86400),
                                                      types: band == "CS" ? ["CS", "SKY"] : [band],
                                                      cacheKey: "guide-" + key))
        cache[key] = list
        return list
    }

    /// 表示中の日が出たら、残りの日も 1 日ずつ裏で取っておく（日付を切り替えたときに待たないように）。
    /// 端末に 1 時間以内の分があれば取らない。日付や放送波を切り替えると task ごと止まる
    private func prefetchOtherDays() async {
        guard let es = Servers.epgstation else { return }
        for offset in 0..<Self.dayCount where offset != dayOffset {
            if Task.isCancelled { return }
            let key = cacheKey(offset)
            if cache[key] != nil { continue }
            if (DiskCache.age("guide-" + key) ?? .infinity) < 3600,
               let saved = EPGStationClient.cachedSchedules(key: "guide-" + key), !saved.isEmpty {
                cache[key] = Self.sorted(saved)
                continue
            }
            _ = try? await fetch(offset, es: es)
        }
    }

    private static func sorted(_ list: [ESSchedule]) -> [ESSchedule] {
        list.sorted { ($0.channel.remoteControlKeyId ?? 999, $0.channel.serviceId ?? 0)
                    < ($1.channel.remoteControlKeyId ?? 999, $1.channel.serviceId ?? 0) }
    }

    /// このセッションで取れたものはそのまま使う。端末に前回の分があればまずそれを出し、裏で取り直す
    /// （番組表は 1 日 1MB 前後あり、毎回待つと「接続中」が長い）
    private func load() async {
        let key = cacheKey(dayOffset)
        if let c = cache[key] { columns = c; errorText = nil; return }
        let diskKey = "guide-" + key
        var showingStale = false
        if let saved = EPGStationClient.cachedSchedules(key: diskKey), !saved.isEmpty {
            columns = Self.sorted(saved)
            errorText = nil
            showingStale = true
        }
        guard let es = Servers.epgstation else { errorText = "EPGStation の URL が設定されていません"; return }
        loading = true
        defer { loading = false }
        do {
            columns = try await fetch(dayOffset, es: es)
            errorText = nil
        } catch {
            if !showingStale { errorText = describeError(error) }
            DebugLog.log("net", "番組表の取得に失敗\(showingStale ? "（前回の分で表示中）" : ""): \(describeError(error))")
        }
    }
}

// MARK: - 番組詳細・録画予約（ボトムシート）

/// DESIGN.md「番組詳細・録画予約（ProgramDetail）」
struct ProgramDetailSheet: View {
    let selection: GuideSelection
    @EnvironmentObject private var reserves: ReserveStore
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var showRule = false

    private var program: Program { selection.program }
    private var reserve: ESReserve? { reserves.reserve(forProgram: program.id) }
    private var isPast: Bool { program.end < Date() }

    private var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "M/d(E)"
        return "\(f.string(from: program.start)) \(program.timeRange)（\(Int(program.durationMinutes))分）"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        LogoTile(url: Servers.epgstation?.logoURL(channelId: selection.channel.id), size: Theme.Logo.card)
                        Text(selection.channel.remoteControlKeyId.map(String.init) ?? "")
                            .font(Theme.F.mono(15)).foregroundStyle(Theme.C.accent)
                        Text(selection.channel.name).font(Theme.F.jp(15, .bold)).foregroundStyle(Theme.C.text)
                        Spacer()
                        CircleButton(systemName: "xmark", size: 36) { dismiss() }
                    }
                    Text(program.title).font(Theme.F.jp(22, .bold)).foregroundStyle(Theme.C.text).lineSpacing(4)
                    Text(dateText).font(Theme.F.mono(13, .medium)).foregroundStyle(Theme.C.text3)

                    let tags = program.genreNames + program.marks.map { markName($0) }
                    if !tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(tags, id: \.self) { TagView(text: $0) }
                        }
                    }
                    banner
                    if !program.detailText.isEmpty {
                        Text(program.detailText).font(Theme.F.jp(13)).foregroundStyle(Theme.C.text3).lineSpacing(3)
                    }
                }
                .padding(20)
            }
            actions
        }
        .background(Theme.C.surface.ignoresSafeArea())
        .presentationDetents([.large, .fraction(0.8)])
        .presentationCornerRadius(Theme.R.sheet)
        .sheet(isPresented: $showRule) {
            RuleSheet(selection: selection).environmentObject(reserves)
        }
    }

    private func markName(_ m: String) -> String {
        switch m {
        case "字": "字幕"
        case "デ": "データ放送"
        case "多": "多言語"
        case "二": "二か国語"
        case "新": "新番組"
        case "終": "最終回"
        case "再": "再放送"
        default: m
        }
    }

    @ViewBuilder private var banner: some View {
        if let r = reserve {
            if r.isConflict == true {
                bannerBox(text: "⚠ 他の予約と重なっていて、録画されない可能性があります",
                       fg: Theme.C.warnText, bg: Theme.C.warnTint, border: Theme.C.warnTintBorder)
            } else if r.isSkip == true {
                bannerBox(text: "この予約はスキップされています", fg: Theme.C.warnText, bg: Theme.C.warnTint, border: Theme.C.warnTintBorder)
            } else {
                bannerBox(text: "録画予約済み · EPGStation", fg: Theme.C.recText, bg: Theme.C.recTint, border: Theme.C.recTintBorder)
            }
        }
    }

    private func bannerBox(text: String, fg: Color, bg: Color, border: Color) -> some View {
        Text(text).font(Theme.F.jp(13, .bold)).foregroundStyle(fg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(bg, in: RoundedRectangle(cornerRadius: Theme.R.button))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.button).stroke(border))
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if let message {
                Text(message).font(Theme.F.caption).foregroundStyle(Theme.C.rec)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let r = reserve {
                Button { Task { message = await reserves.cancel(reserveId: r.id) } } label: {
                    Text("予約を取り消す").font(Theme.F.jp(16, .bold)).foregroundStyle(Theme.C.recText)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.C.recTintBorder))
                }
                .buttonStyle(.plain)
                .disabled(reserves.busy)
            } else {
                Button { Task { message = await reserves.add(programId: program.id) } } label: {
                    Text(isPast ? "終了した番組です" : "録画予約").font(Theme.F.jp(16, .bold)).foregroundStyle(Theme.C.onRec)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.C.rec, in: RoundedRectangle(cornerRadius: Theme.R.card))
                        .opacity(isPast ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isPast || reserves.busy)
            }
            HStack(spacing: 10) {
                Button { showRule = true } label: { secondaryLabel("毎週録画ルール", enabled: true) }
                    .buttonStyle(.plain)
                secondaryLabel("録画オプション", enabled: false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .background(Theme.C.surface)
    }

    private func secondaryLabel(_ label: String, enabled: Bool) -> some View {
        Text(label).font(Theme.F.jp(13, .medium)).foregroundStyle(enabled ? Theme.C.text2 : Theme.C.muted)
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay(RoundedRectangle(cornerRadius: Theme.R.button).stroke(Theme.C.borderStrong))
    }
}
