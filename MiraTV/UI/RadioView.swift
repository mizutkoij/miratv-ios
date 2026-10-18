import SwiftUI

/// DESIGN.md「ラジオ（Radio）」「ラジオ局詳細（RadioStation）」の実装
struct RadioView: View {
    @AppStorage("radioWebURL") private var serverURL = Defaults.radioWebURL
    @EnvironmentObject private var radio: RadioPlayer

    @State private var catalog: RadioCatalog?
    @State private var region: String?
    @State private var query = ""
    @State private var errorText: String?
    @State private var loading = false

    private var client: RadioWebClient? { RadioWebClient(serverURL) }

    private var regions: [String] {
        guard let catalog else { return [] }
        let present = Set(catalog.stations.compactMap(\.region))
        let ordered = catalog.regionOrder.filter(present.contains)
        return ordered + present.subtracting(ordered).sorted()
    }

    private var visible: [RadioStation] {
        guard let catalog else { return [] }
        // NHK は radiko 経由（番組表・聴き逃し付き）と NHK 直接（ライブのみ）の 2 通りで載っている。
        // 同じ名前なら radiko 側の 1 行にまとめる（過去は NHK 専用アーカイブにも引き継ぐ）
        let radikoNHK = Set(catalog.stations.filter(\.isRadikoNHK).map(\.name))
        return catalog.stations.filter { s in
            !(s.source == .nhk && radikoNHK.contains(s.name))
            && (region == nil || s.region == region)
            && (query.isEmpty || s.name.localizedCaseInsensitiveContains(query))
        }
    }

    private var statusText: String {
        if let errorText { return errorText }
        guard let catalog else { return loading ? "接続中…" : "radio-web" }
        let n = catalog.stations.filter(RadioStreamResolver.isNativelyPlayable).count
        return "radio-web · \(n) 局が再生可"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.C.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    ScreenHeader(title: "ラジオ",
                                 status: StatusLine(text: statusText,
                                                    color: errorText == nil ? Theme.C.live : Theme.C.rec)) {
                        EmptyView()
                    }
                    searchField
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ChipView(label: "すべて", selected: region == nil) { region = nil }
                            ForEach(regions, id: \.self) { r in
                                ChipView(label: r, selected: region == r) { region = r }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .padding(.vertical, 10)

                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(visible, id: \.key) { s in
                                NavigationLink(value: s) { StationRow(station: s) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 16)
                    }
                    .refreshable { await load() }
                }
            }
            .navigationDestination(for: RadioStation.self) { s in
                if let client { RadioStationView(station: s, client: client) }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) { RadioMiniPlayer() }
            .task(id: serverURL) { await load() }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.C.text4)
            TextField("局名で検索", text: $query)
                .font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.C.surface, in: RoundedRectangle(cornerRadius: Theme.R.button))
        .padding(.horizontal, 12)
    }

    /// 前回の局カタログがあればすぐ出して、裏で取り直す（取り直しに失敗しても前回の分で使える）
    private func load() async {
        guard let client else { errorText = "URL が不正です"; return }
        radio.configure(client: client)
        if catalog == nil, let cached = client.cachedStations() { catalog = cached }
        loading = true
        defer { loading = false }
        do { catalog = try await client.stations(); errorText = nil }
        catch {
            if catalog == nil { errorText = "局一覧の取得に失敗: \(describeError(error))" }
            DebugLog.log("radio", "局一覧の更新に失敗: \(describeError(error))")
        }
    }
}

private struct StationRow: View {
    let station: RadioStation

    private var trailing: (text: String, color: Color) {
        if !RadioStreamResolver.isNativelyPlayable(station) { return ("未対応", Theme.C.muted) }
        return station.source == .radiko ? ("アーカイブ", Theme.C.accent) : ("ライブ", Theme.C.text3)
    }

    var body: some View {
        HStack(spacing: 12) {
            LogoTile(url: station.logo.flatMap(URL.init(string:)), size: Theme.Logo.radio)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(station.name).font(Theme.F.rowTitle).foregroundStyle(Theme.C.text).lineLimit(1)
                    TagView(text: station.source.label)
                }
                if let t = station.current?.title, !t.isEmpty {
                    Text(t).font(Theme.F.caption).foregroundStyle(Theme.C.text3).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(trailing.text).font(Theme.F.jp(12, .medium)).foregroundStyle(trailing.color)
        }
        .rowCard()
    }
}

/// 局詳細：ライブ + 日付ごとの番組表。nzb がある回はアーカイブ再生
struct RadioStationView: View {
    let station: RadioStation
    let client: RadioWebClient
    @EnvironmentObject private var radio: RadioPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var items: [RadioScheduleItem] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var showPicker = false
    @State private var picked = Date()

    /// 再生できる nzb アーカイブの先頭（実機ではなくサーバーで再生要求して確認: 7/9 以前は nzb ファイルが無く 502。
    /// 一覧（DB）には 5/13 から載るが、Discord の nzb バックアップは 2026-07-07 が最古で、旧 VPS1 の消失(9/5)で原本が無い）
    private var archiveStart: Date {
        // NHK は専用の取り込みが始まった 2026-09-08 ごろから（それ以前は数日に 1 件だけ）
        var c = DateComponents(); c.year = 2026
        if station.nhkArchiveKey != nil { c.month = 9; c.day = 8 } else { c.month = 7; c.day = 13 }
        return Calendar.current.date(from: c) ?? Date.distantPast
    }

    private var days: [Date] {
        (0..<8).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: Calendar.current.startOfDay(for: Date())) }
    }

    /// radiko はスケジュール API、NHK は番組表が無いので archive/search（radiru の録音）から行を作る
    private var hasSchedule: Bool { station.source == .radiko || station.source == .nhk }

    private var playingNzb: String? {
        if case .archive(let nzb) = radio.mode { return nzb }
        return nil
    }

    var body: some View {
        ZStack {
            Theme.C.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        liveCard
                        if hasSchedule {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(days, id: \.self) { d in
                                        ChipView(label: dayLabel(d), selected: d == day) { day = d }
                                    }
                                    // 8 日より前（アーカイブの先頭まで）は日付を選んで開く
                                    if !days.contains(day) { ChipView(label: dayLabel(day), selected: true) { picked = day; showPicker = true } }
                                    ChipView(label: "それ以前…", selected: false) { picked = day; showPicker = true }
                                }
                            }
                            Text(loading ? "読み込み中…" : "番組表").font(Theme.F.section).foregroundStyle(Theme.C.text)
                            if let errorText { Text(errorText).font(Theme.F.caption).foregroundStyle(Theme.C.rec) }
                            VStack(spacing: 6) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                    scheduleButton(i, item)
                                }
                            }
                        } else {
                            Text("この局は番組表・過去放送に未対応です（ライブのみ）")
                                .font(Theme.F.caption).foregroundStyle(Theme.C.muted)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { RadioMiniPlayer() }
        .task(id: day) { await load() }
        .sheet(isPresented: $showPicker) { datePickerSheet }
    }

    private var datePickerSheet: some View {
        NavigationStack {
            VStack(spacing: 8) {
                DatePicker("日付", selection: $picked, in: archiveStart...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .environment(\.locale, Locale(identifier: "ja_JP"))
                Text(station.nhkArchiveKey != nil ? "NHK のアーカイブ（全国放送分）は 2026年9月8日 以降です。直近 7 日は radiko の聴き逃しです"
                                            : "再生できるアーカイブは 2026年7月13日 以降です（それ以前は一覧に出ても、元の nzb が失われていて再生できません）")
                    .font(Theme.F.caption).foregroundStyle(Theme.C.text3)
                    .padding(.horizontal, 16)
                Spacer()
            }
            .navigationTitle("日付を選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { showPicker = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("決定") { day = Calendar.current.startOfDay(for: picked); showPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            CircleButton(systemName: "chevron.left") { dismiss() }
            LogoTile(url: station.logo.flatMap(URL.init(string:)), size: Theme.Logo.radio)
            VStack(alignment: .leading, spacing: 2) {
                Text(station.name).font(Theme.F.jp(18, .bold)).foregroundStyle(Theme.C.text).lineLimit(1)
                Text([station.source.label, station.region].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.F.caption).foregroundStyle(Theme.C.text3)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var liveCard: some View {
        let playable = RadioStreamResolver.isNativelyPlayable(station)
        return Button { radio.playLive(station) } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.fill")
                    .font(.system(size: 18)).foregroundStyle(Theme.C.onAccent)
                    .frame(width: 44, height: 44).background(Theme.C.accent, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("ライブで聴く").font(Theme.F.jp(16, .bold)).foregroundStyle(Theme.C.text)
                    if let t = station.current?.title {
                        Text(t).font(Theme.F.caption).foregroundStyle(Theme.C.text3).lineLimit(1)
                    }
                }
                Spacer()
                Text("LIVE").font(Theme.F.jp(11, .bold)).foregroundStyle(Theme.C.recText)
            }
            .padding(12)
            .background(Theme.C.accentTint, in: RoundedRectangle(cornerRadius: Theme.R.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.C.rowActiveBorder))
            .opacity(playable ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!playable)
    }

    // MARK: 聴き逃し（radiko の過去 7 日をそのまま）

    private static let jst: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Tokyo")!; return c
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo"); f.dateFormat = "yyyyMMddHHmmss"; return f
    }()

    /// この番組を radiko の聴き逃しで聴けるなら、その開始・終了。放送日は 05:00 区切り（0〜4 時台は翌暦日）。
    /// 終了済みで、開始が 7 日以内のものだけ
    private func pastEntry(_ item: RadioScheduleItem) -> RadioPlayer.PastEntry? {
        guard station.source == .radiko, let len = item.lengthSeconds else { return nil }
        let p = item.ft.raw.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        var c = Self.jst.dateComponents([.year, .month, .day], from: day)
        c.hour = h; c.minute = m
        guard var start = Self.jst.date(from: c) else { return nil }
        if h < 5 { start = start.addingTimeInterval(86400) }
        let end = start.addingTimeInterval(len)
        guard end <= Date(), start >= Date().addingTimeInterval(-7 * 86400) else { return nil }
        return RadioPlayer.PastEntry(item: item, ft: Self.stamp.string(from: start), to: Self.stamp.string(from: end))
    }

    private func scheduleButton(_ i: Int, _ item: RadioScheduleItem) -> some View {
        let past = pastEntry(item)
        let isPlayingArchive = item.nzb != nil && item.nzb == playingNzb
        let isPlayingPast: Bool = {
            guard let past, case .timefree(let id) = radio.mode else { return false }
            return id == past.id(station: station.id)
        }()
        let isPlaying = isPlayingArchive || isPlayingPast
        let playable = past != nil || item.isArchived
        let playingIndex = items.firstIndex { $0.nzb != nil && $0.nzb == playingNzb }
        let isNext = playingIndex.map { i == $0 + 1 && item.isArchived } ?? false
        return Button {
            if item.isArchived {
                // アーカイブ(nzb)があればそれが本命（5 月中旬から約半年分）
                radio.playArchive(item, stationName: station.name, queue: Array(items.dropFirst(i + 1)))
            } else if let past {
                // まだアーカイブされていない直近の番組（放送後 1 日くらい）だけ、radiko の聴き逃しで埋める
                let rest = items.dropFirst(i + 1).filter { !$0.isArchived }.compactMap(pastEntry)
                radio.playPast(past, station: station, queue: Array(rest))
            }
        } label: {
            ScheduleRow(item: item, state: isPlaying ? "再生中" : (isNext ? "次に再生" : (playable ? "▶" : "")),
                        active: isPlaying)
        }
        .buttonStyle(.plain)
        .disabled(!playable)
    }

    private func dayLabel(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "今日" }
        if Calendar.current.isDateInYesterday(d) { return "昨日" }
        let old = d < Calendar.current.date(byAdding: .day, value: -180, to: Date())!   // 通常は出ないが、年をまたぐ日付に備える
        return d.formatted(old ? .dateTime.year().month(.defaultDigits).day().weekday(.short) : .dateTime.month(.defaultDigits).day().weekday(.short))
    }

    /// 前回取れた番組表があればすぐ出す。過去の日は内容が変わらないので、取り直さない
    private func load() async {
        guard hasSchedule else { return }
        if station.source == .nhk { await loadNHK(); return }
        // radiko の NHK は、聴き逃しの窓（7 日）より前は NHK 専用の nzb アーカイブから引く
        if station.isRadikoNHK, day <= Calendar.current.startOfDay(for: Date()).addingTimeInterval(-7 * 86400) {
            await loadNHK(); return
        }
        // 放送日は 05:00 区切り。0〜5 時の「昨日」はまだ放送中なので取り直す
        let broadcastToday = Calendar.current.startOfDay(for: Date().addingTimeInterval(-5 * 3600))
        let isPast = day < broadcastToday
        let key = RadioWebClient.scheduleCacheKey(source: station.source, station: station.id, date: day)
        if let saved = client.cachedSchedule(source: station.source, station: station.id, date: day) {
            items = saved.items
            errorText = nil
            // 終わった日で、保存から 6 時間以内なら取り直さない（アーカイブは後から増えたり期限で消えたりするため、ずっとは使わない）
            if isPast, saved.items.contains(where: \.isArchived), (DiskCache.age(key) ?? .infinity) < 6 * 3600 { return }
        } else {
            items = []
        }
        loading = true; defer { loading = false }
        do {
            items = try await client.schedule(source: station.source, station: station.id, date: day).items
            errorText = nil
        } catch {
            if items.isEmpty { errorText = describeError(error) }
        }
    }
}

extension RadioStationView {
    /// NHK は radiko の聴き逃しが使えない（radiko 側が禁止）ので、録音済みの回だけを日付で引いて並べる。
    /// 番組表は無いので、録音がある回だけが行になる
    fileprivate func loadNHK() async {
        let key = station.nhkArchiveKey ?? "nhk:R1"
        items = []
        loading = true; defer { loading = false }
        do {
            let hits = try await client.archiveSearch(station: key, q: nil, date: day)
            items = hits.sorted { ($0.onair ?? "") < ($1.onair ?? "") }.map(Self.nhkItem)
            errorText = nil
        } catch {
            errorText = describeError(error)
        }
    }

    /// onair は "2026-10-18T23:05:00+09:00"。終了時刻は分からないので to = ft（長さ 0）にしておく。
    /// 長さ 0 だと RadioPlayer.shouldSkipHead が false になり、radiko 用の頭 25 秒スキップが掛からない（NHK の録音には継ぎ足しが無い）
    fileprivate static func nhkItem(_ hit: RadioArchiveHit) -> RadioScheduleItem {
        let o = hit.onair ?? ""
        let hhmm = o.count >= 16 ? String(o.dropFirst(11).prefix(5)) : "--:--"
        return RadioScheduleItem(ft: RadioTime(raw: hhmm), to: RadioTime(raw: hhmm), title: hit.title,
                                 pfm: hit.sub, thumbnail: hit.thumbnail, nzb: hit.nzb)
    }
}

private struct ScheduleRow: View {
    let item: RadioScheduleItem
    let state: String
    let active: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(item.ft.date?.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()) ?? item.ft.raw)
                .font(Theme.F.mono(13)).foregroundStyle(item.isArchived ? Theme.C.text4 : Theme.C.muted)
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Theme.F.jp(14, .bold))
                    .foregroundStyle(item.isArchived ? Theme.C.text : Theme.C.muted)
                if let p = item.pfm, !p.isEmpty {
                    Text(p).font(Theme.F.caption).foregroundStyle(Theme.C.text3).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(state).font(Theme.F.jp(12, .medium))
                .foregroundStyle(active ? Theme.C.accent : Theme.C.text3)
        }
        .rowCard(active: active)
    }
}

/// 下部に常駐するミニプレイヤー。アーカイブ準備中は経過秒を出す（初回は 40 秒前後）
struct RadioMiniPlayer: View {
    @EnvironmentObject private var radio: RadioPlayer

    var body: some View {
        if radio.mode != .idle {
            VStack(spacing: 8) {
                if radio.mode.isOnDemand, radio.duration > 0 {
                    ProgressBar(progress: radio.position / radio.duration)
                }
                HStack(spacing: 10) {
                    AsyncImage(url: radio.now.artworkURL) { phase in
                        if let img = phase.image { img.resizable().scaledToFill() } else { Theme.C.surface }
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(radio.now.title.isEmpty ? radio.now.stationName : radio.now.title)
                            .font(Theme.F.jp(14, .bold)).foregroundStyle(Theme.C.text).lineLimit(1)
                        statusLine
                    }
                    Spacer(minLength: 4)
                    if radio.mode.isOnDemand {
                        Button { radio.seek(by: -15) } label: { Image(systemName: "gobackward.15") }
                            .frame(width: 36, height: 44)
                        Button { radio.seek(by: 30) } label: { Image(systemName: "goforward.30") }
                            .frame(width: 36, height: 44)
                    }
                    Button { radio.togglePause() } label: {
                        Image(systemName: radio.phase == .playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 18)).foregroundStyle(Theme.C.onAccent)
                            .frame(width: 44, height: 44).background(Theme.C.accent, in: Circle())
                    }
                    .accessibilityLabel(radio.phase == .playing ? "一時停止" : "再生")
                    Button { radio.stop() } label: { Image(systemName: "xmark") }
                        .frame(width: 32, height: 44).accessibilityLabel("停止")
                }
                .foregroundStyle(Theme.C.text2)
            }
            .padding(10)
            .background(Theme.C.raised, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0x2A3038)))
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch radio.phase {
        case .preparing(let since):
            TimelineView(.periodic(from: since, by: 1)) { ctx in
                Text("アーカイブを準備中… \(Int(ctx.date.timeIntervalSince(since)))秒")
                    .font(Theme.F.caption).foregroundStyle(Theme.C.text3)
            }
        case .buffering:
            Text("\(radio.now.stationName) · 読み込み中").font(Theme.F.caption).foregroundStyle(Theme.C.text3)
        case .failed(let msg):
            Text(msg).font(Theme.F.caption).foregroundStyle(Theme.C.rec).lineLimit(3)
        default:
            if case .live = radio.mode {
                HStack(spacing: 6) {
                    Text("LIVE").font(Theme.F.jp(10, .bold)).foregroundStyle(Theme.C.recText)
                    Text(radio.now.stationName).font(Theme.F.caption).foregroundStyle(Theme.C.text3)
                }
            } else {
                Text("\(radio.now.stationName) · \(format(radio.position)) / \(format(radio.duration))")
                    .font(Theme.F.caption).foregroundStyle(Theme.C.text3)
            }
        }
    }

    private func format(_ s: Double) -> String {
        guard s.isFinite else { return "--:--" }
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}
