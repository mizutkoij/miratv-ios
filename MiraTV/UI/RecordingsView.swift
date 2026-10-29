import SwiftUI
import AVKit

/// DESIGN.md「録画（Recordings）」: 予約 / 録画済み / ルール
struct RecordingsView: View {
    enum Segment: String, CaseIterable { case reserves = "予約", recorded = "録画済み", rules = "ルール", archive = "アーカイブ" }

    @AppStorage("epgstationURL") private var epgURL = Defaults.epgstationURL
    @AppStorage("epgstation2URL") private var epg2URL = Defaults.epgstation2URL
    @EnvironmentObject private var reserves: ReserveStore
    @EnvironmentObject private var epg: EPGStore
    @EnvironmentObject private var session: PlaybackSession
    @ObservedObject private var archive = UsenetCatalog.shared

    @State private var segment: Segment = .reserves
    @State private var recorded: [ESRecorded] = []
    @State private var recordedTotal = 0
    /// 2 台目の EPGStation（韓国・配信系）の録画。録画済みの一覧で 1 台目のものと混ぜて出す
    @State private var recorded2: [ESRecorded] = []
    @State private var recordedTotal2 = 0
    @State private var names2: [Int: String] = [:]
    @State private var rules: [ESRule] = []
    @State private var storageText = ""
    @State private var errorText: String?
    @State private var loading = false
    @State private var ruleToDelete: ESRule?
    @State private var now = Date()
    @State private var showCaptionSearch = false
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var es: EPGStationClient? { EPGStationClient(epgURL) }
    private var es2: EPGStationClient? {
        let s = epg2URL.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : EPGStationClient(s)
    }

    /// 録画済みの一覧の 1 行（どちらの EPGStation のものか）。番号は別々に振られているので、行の ID は組にする
    private struct RecItem: Identifiable {
        let rec: ESRecorded
        let es: EPGStationClient
        let second: Bool
        var id: String { "\(second ? 2 : 1)-\(rec.id)" }
    }

    /// 両方の EPGStation の録画を、開始が新しい順に
    private var merged: [RecItem] {
        var out: [RecItem] = []
        if let es { out += recorded.map { RecItem(rec: $0, es: es, second: false) } }
        if let es2 { out += recorded2.map { RecItem(rec: $0, es: es2, second: true) } }
        return out.sorted { $0.rec.startAt > $1.rec.startAt }
    }

    private var statusLine: StatusLine {
        if segment == .archive { return archiveStatus }
        if let errorText { return StatusLine(text: errorText, color: Theme.C.rec) }
        return StatusLine(text: "EPGStation \(storageText.isEmpty ? "" : "· 空き \(storageText)")")
    }

    var body: some View {
        ZStack {
            Theme.C.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "録画", status: statusLine) {
                    HStack(spacing: 8) {
                        if segment == .archive {
                            // タップで新しい分だけ。長押しで全件を取り直す（件数が合わないときなど）
                            CircleButton(systemName: "arrow.clockwise") { Task { await archive.refresh() } }
                                .contextMenu {
                                    Button { Task { await archive.refresh(full: true) } } label: {
                                        Label("一覧を全件取り直す", systemImage: "arrow.triangle.2.circlepath")
                                    }
                                }
                                .disabled(archive.syncing)
                        } else {
                            if Servers.chapters != nil {
                                CircleButton(systemName: "text.magnifyingglass") { showCaptionSearch = true }
                                    .accessibilityLabel("字幕で探す")
                            }
                            CircleButton(systemName: "arrow.clockwise") { Task { await load(force: true) } }
                        }
                    }
                }
                SegmentedPills(options: Segment.allCases, label: { $0.rawValue }, selection: $segment)
                    .padding(.horizontal, 12).padding(.bottom, 10)

                if segment == .archive {
                    // 検索欄を上に固定し、7 万件の一覧を自前のスクロールで出す
                    UsenetArchiveView()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            switch segment {
                            case .reserves: reserveRows
                            case .recorded: recordedRows
                            case .rules: ruleRows
                            case .archive: EmptyView()
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 16)
                    }
                    .refreshable { await load(force: true) }
                }
            }
        }
        .task(id: "\(segment.rawValue)-\(epgURL)") { await load(force: false) }
        .onReceive(ticker) { now = $0 }
        .sheet(isPresented: $showCaptionSearch) {
            if let es, let c = Servers.chapters {
                CaptionSearchSheet(client: c, es: es, recordings: recorded)
            }
        }
        .confirmationDialog("このルールを削除しますか？", isPresented: Binding(get: { ruleToDelete != nil }, set: { if !$0 { ruleToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("ルールを削除", role: .destructive) {
                if let r = ruleToDelete {
                    Task {
                        if let err = await reserves.deleteRule(id: r.id) { errorText = err } else { await load(force: true) }
                    }
                }
                ruleToDelete = nil
            }
            Button("キャンセル", role: .cancel) { ruleToDelete = nil }
        } message: {
            Text("「\(ruleToDelete?.keyword ?? "")」のルールと、そこから作られた予約が消えます。録画済みの番組は消えません。")
        }
    }

    // MARK: - 予約

    private func channelName(_ id: Int) -> String { epg.channelInfo[id]?.name ?? "ch \(id)" }

    private var reserveRows: some View {
        let list = reserves.reserves.sorted { $0.startAt < $1.startAt }
        return Group {
            if list.isEmpty { empty("予約はありません") }
            ForEach(list) { r in
                reserveRow(r)
                    .contextMenu {
                        Button(role: .destructive) { Task { _ = await reserves.cancel(reserveId: r.id) } } label: {
                            Label("予約を取り消す", systemImage: "trash")
                        }
                    }
            }
        }
    }

    private func reserveRow(_ r: ESReserve) -> some View {
        let recordingNow = r.start <= now && now < r.end && r.isConflict != true && r.isSkip != true
        let state: (text: String, color: Color) =
            r.isConflict == true ? ("▲ 競合", Theme.C.warn)
            : r.isSkip == true ? ("スキップ", Theme.C.muted)
            : recordingNow ? ("● 録画中", Theme.C.recText)
            : (r.ruleId != nil ? "ルール予約" : "予約", Theme.C.text3)
        let border: Color = recordingNow ? Theme.C.recTintBorder : (r.isConflict == true ? Theme.C.warnTintBorder : Color.clear)

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dateText(r.start)).font(Theme.F.jp(11)).foregroundStyle(Theme.C.text4)
                Text(r.start.hm).font(Theme.F.mono(15)).foregroundStyle(Theme.C.text)
            }
            .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(channelName(r.channelId)).font(Theme.F.caption).foregroundStyle(Theme.C.text3)
                Text(r.name ?? "").font(Theme.F.jp(14, .bold)).foregroundStyle(Theme.C.text).lineLimit(2)
                Text(state.text).font(Theme.F.jp(12, .medium)).foregroundStyle(state.color)
            }
            Spacer(minLength: 4)
            Circle().fill(state.color).frame(width: 10, height: 10).padding(.top, 4)
        }
        .padding(12)
        .background(Theme.C.row, in: RoundedRectangle(cornerRadius: Theme.R.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(border))
    }

    private func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "M/d(E)"
        return f.string(from: d)
    }

    // MARK: - 録画済み

    private var recordedRows: some View {
        Group {
            if recorded.isEmpty && recorded2.isEmpty && !loading { empty("録画はありません") }
            ForEach(merged) { item in
                Button { session.playRecorded(item.rec, es: item.es) } label: { recordedRow(item) }
                    .buttonStyle(.plain)
                    .disabled(item.rec.videoFiles?.isEmpty ?? true)
            }
            if recorded.count < recordedTotal || recorded2.count < recordedTotal2 {
                Button { Task { await loadMoreRecorded() } } label: {
                    Text("もっと読み込む（\(recorded.count + recorded2.count)/\(recordedTotal + recordedTotal2)）")
                        .font(Theme.F.jp(13, .medium)).foregroundStyle(Theme.C.text2)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func recordedRow(_ item: RecItem) -> some View {
        let rec = item.rec
        let kind = rec.videoFiles?.first?.type == "encoded" ? "MP4" : "TS"
        return HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: rec.thumbnails?.first.flatMap { item.es.thumbnailURL(id: $0) }) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() } else { Theme.C.surface }
                }
                .frame(width: 136, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // どこまで見たか（続きから再生できる録画だけ）
                .overlay(alignment: .bottom) {
                    if let p = WatchPositions.progress(rec.id, duration: rec.durationSeconds) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color.black.opacity(0.5))
                                Rectangle().fill(Theme.C.accent).frame(width: g.size.width * p)
                            }
                        }
                        .frame(height: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    }
                }
                Text(duration(rec.durationSeconds)).font(Theme.F.mono(10, .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 4).background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                    .padding(4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(rec.name ?? "").font(Theme.F.jp(14, .bold)).foregroundStyle(Theme.C.text).lineLimit(2)
                Text("\(rec.channelId.map { item.second ? (names2[$0] ?? channelName($0)) : channelName($0) } ?? "") · \(dateText(rec.start)) \(rec.start.hm)")
                    .font(Theme.F.caption).foregroundStyle(Theme.C.text3).lineLimit(1)
                HStack(spacing: 6) {
                    TagView(text: kind)
                    if item.second { TagView(text: "2台目") }
                    if rec.isRecording == true { Text("● 録画中").font(Theme.F.jp(11, .bold)).foregroundStyle(Theme.C.recText) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.C.row, in: RoundedRectangle(cornerRadius: Theme.R.card))
    }

    private func duration(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: - ルール

    private var ruleRows: some View {
        Group {
            if rules.isEmpty && !loading { empty("ルールはありません") }
            ForEach(rules) { rule in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.keyword?.isEmpty == false ? rule.keyword! : (rule.isTimeSpecification == true ? "時間指定" : "（キーワードなし）"))
                            .font(Theme.F.jp(15, .bold)).foregroundStyle(rule.enable ? Theme.C.text : Theme.C.muted).lineLimit(2)
                        Text(ruleSummary(rule)).font(Theme.F.caption).foregroundStyle(Theme.C.text3).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Text("\(rule.reservesCnt ?? 0) 件").font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text3)
                }
                .padding(12)
                .background(Theme.C.row, in: RoundedRectangle(cornerRadius: Theme.R.card))
                .contextMenu {
                    Button(role: .destructive) { ruleToDelete = rule } label: { Label("ルールを削除", systemImage: "trash") }
                }
            }
        }
    }

    /// 「毎週 月・水 20時台〜（1時間）· TBS1」のような説明
    private func ruleSummary(_ rule: ESRule) -> String {
        let names = ["日", "月", "火", "水", "木", "金", "土"]
        var parts: [String] = []
        if let t = rule.times.first {
            if let w = t.week, w != 0, w != 127 {
                parts.append("毎週 " + (0..<7).filter { w & (1 << $0) != 0 }.map { names[$0] }.joined(separator: "・"))
            } else {
                parts.append("毎日")
            }
            if let s = t.start, let r = t.range { parts.append("\(s) 時台〜（\(r) 時間）") }
        }
        let ch = rule.channelIds.compactMap { epg.channelInfo[$0]?.name }
        if !ch.isEmpty { parts.append(ch.joined(separator: "・")) }
        if !rule.enable { parts.append("無効") }
        return parts.isEmpty ? (rule.isTimeSpecification == true ? "時間指定予約" : "キーワード予約") : parts.joined(separator: " · ")
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(Theme.F.meta).foregroundStyle(Theme.C.muted)
            .frame(maxWidth: .infinity).padding(.top, 40)
    }

    // MARK: - 読み込み

    private var archiveStatus: StatusLine {
        if archive.syncing {
            let total = archive.progressTotal.map { " / \($0)" } ?? ""
            return StatusLine(text: "Usenet · 一覧を取得中 \(archive.progressDone)\(total)", color: Theme.C.warn)
        }
        if let e = archive.error { return StatusLine(text: e, color: Theme.C.rec) }
        let updated = archive.lastSync.map { " · 更新 \($0.hm)" } ?? ""
        return StatusLine(text: "Usenet · \(archive.entries.count) 番組\(updated)")
    }

    private func load(force: Bool) async {
        if segment == .archive { return }       // アーカイブは UsenetArchiveView が自分で読む（EPGStation は使わない）
        guard let es else { errorText = "EPGStation の URL が設定されていません"; return }
        loading = true
        defer { loading = false }
        await epg.refreshOverview(es: es)
        if let s = try? await es.storages(), let st = s.first, let avail = st.available {
            storageText = ByteCountFormatter.string(fromByteCount: avail, countStyle: .file)
        }
        do {
            switch segment {
            case .reserves:
                await reserves.refresh()
                errorText = reserves.error
            case .recorded:
                if force || recorded.isEmpty {
                    let r = try await es.recorded(offset: 0, limit: 30)
                    recorded = r.records; recordedTotal = r.total
                    await loadSecondRecorded(offset: 0)
                }
                errorText = nil
            case .rules:
                rules = try await es.rules()
                errorText = nil
            case .archive:
                break
            }
        } catch {
            errorText = describeError(error)
        }
    }

    private func loadMoreRecorded() async {
        if let es, recorded.count < recordedTotal {
            do {
                let r = try await es.recorded(offset: recorded.count, limit: 30)
                recorded += r.records
                recordedTotal = r.total
            } catch { errorText = describeError(error) }
        }
        if recorded2.count < recordedTotal2 { await loadSecondRecorded(offset: recorded2.count) }
    }

    /// 2 台目の EPGStation の録画。つながらなくても 1 台目の一覧は出す
    private func loadSecondRecorded(offset: Int) async {
        guard let es2 else { recorded2 = []; recordedTotal2 = 0; return }
        do {
            let r = try await es2.recorded(offset: offset, limit: 30)
            if offset == 0 { recorded2 = r.records } else { recorded2 += r.records }
            recordedTotal2 = r.total
            if names2.isEmpty, let chs = try? await es2.channels() {
                names2 = Dictionary(chs.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            }
        } catch {
            DebugLog.log("net", "2 台目の録画一覧を取得できません: \(describeError(error))")
        }
    }
}
