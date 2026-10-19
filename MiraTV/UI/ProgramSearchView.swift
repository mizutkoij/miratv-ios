import SwiftUI

/// 番組表の「番組を探す」: 言葉で番組を探し（EPGStation の番組検索）、タップで番組詳細（予約・毎週録画ルール）を開く
struct ProgramSearchSheet: View {
    @EnvironmentObject private var reserves: ReserveStore
    @EnvironmentObject private var epg: EPGStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage("programSearchHistory") private var historyRaw = ""
    @State private var query = ""
    @State private var band = ""                  // "" = 全部
    @State private var withDescription = false
    @State private var results: [ESProgram] = []
    @State private var searched = false
    @State private var searching = false
    @State private var error: String?
    @State private var selected: GuideSelection?
    @State private var searchTask: Task<Void, Never>?
    @State private var openMessage: String?

    private static let bands: [(String, String)] = [("", "すべて"), ("GR", "地上波"), ("BS", "BS"), ("CS", "CS")]

    private var history: [String] { historyRaw.split(separator: "\n").map(String.init) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "M/d(E)"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 日付ごとにまとめる（放送中・これからの番組だけ）
    private var grouped: [(day: String, items: [ESProgram])] {
        var out: [(String, [ESProgram])] = []
        for p in results {
            let d = Self.dayFormatter.string(from: Date(timeIntervalSince1970: Double(p.startAt) / 1000))
            if out.last?.0 == d { out[out.count - 1].1.append(p) } else { out.append((d, [p])) }
        }
        return out.map { (day: $0.0, items: $0.1) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("放送波", selection: $band) {
                        ForEach(Self.bands, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("概要・詳細も探す", isOn: $withDescription)
                        .font(Theme.F.jp(14)).tint(Theme.C.accent)
                }
                .listRowBackground(Theme.C.surface)

                if !searched && !history.isEmpty {
                    Section("最近探したことば") {
                        ForEach(history, id: \.self) { h in
                            Button(h) { query = h; startSearch() }
                                .font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)
                        }
                    }
                    .listRowBackground(Theme.C.surface)
                }

                if let openMessage {
                    Text(openMessage).font(Theme.F.caption).foregroundStyle(Theme.C.rec).listRowBackground(Theme.C.bg)
                }
                if let error {
                    Text(error).font(Theme.F.caption).foregroundStyle(Theme.C.rec).listRowBackground(Theme.C.bg)
                }
                if searched && results.isEmpty && error == nil && !searching {
                    Text("見つかりませんでした（番組情報があるのはおよそ 8 日先まで）")
                        .font(Theme.F.jp(13)).foregroundStyle(Theme.C.text3).listRowBackground(Theme.C.bg)
                }

                ForEach(grouped, id: \.day) { g in
                    Section(g.day) {
                        ForEach(g.items) { p in
                            Button { open(p) } label: { row(p) }
                                .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(Theme.C.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.C.bg)
            .overlay { if searching { ProgressView().tint(Theme.C.text2) } }
            .navigationTitle(results.isEmpty ? "番組を探す" : "番組を探す（\(results.count) 件）")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "番組名・出演者など")
            .onSubmit(of: .search) { startSearch() }
            .onChange(of: band) { _, _ in if searched { startSearch() } }
            .onChange(of: withDescription) { _, _ in if searched { startSearch() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            .sheet(item: $selected) { sel in
                ProgramDetailSheet(selection: sel).environmentObject(reserves)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ p: ESProgram) -> some View {
        let start = Date(timeIntervalSince1970: Double(p.startAt) / 1000)
        let end = Date(timeIntervalSince1970: Double(p.endAt) / 1000)
        let onAir = start <= Date() && Date() < end
        let reserved = reserves.reserve(forProgram: p.id) != nil
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.timeFormatter.string(from: start)).font(Theme.F.mono(13, .semibold))
                    .foregroundStyle(onAir ? Theme.C.live : Theme.C.text)
                Text(epg.channelInfo[p.channelId]?.name ?? "").font(Theme.F.caption).foregroundStyle(Theme.C.text3)
                    .lineLimit(1).frame(width: 74, alignment: .leading)
            }
            Text(p.name ?? "").font(Theme.F.jp(14, .medium)).foregroundStyle(Theme.C.text).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if reserved {
                Text("予約").font(Theme.F.jp(11, .bold)).foregroundStyle(Theme.C.onAccent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.C.rec, in: Capsule())
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func open(_ p: ESProgram) {
        guard let ch = epg.channelInfo[p.channelId] else { openMessage = "この局の情報がまだありません（番組表を一度開いてください）"; return }
        openMessage = nil
        selected = GuideSelection(program: Program(es: p), channel: ch)
    }

    /// 前の検索は取り消してから（放送波を切り替えたとき、古い結果で上書きしないように）
    private func startSearch() {
        searchTask?.cancel()
        searchTask = Task { await search() }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let es = Servers.epgstation else { return }
        searching = true
        openMessage = nil
        defer { if !Task.isCancelled { searching = false } }
        do {
            let list = try await es.searchPrograms(keyword: q, bands: band.isEmpty ? [] : (band == "CS" ? ["CS", "SKY"] : [band]),
                                                   withDescription: withDescription)
            guard !Task.isCancelled else { return }
            let now = Date().timeIntervalSince1970 * 1000
            results = list.filter { Double($0.endAt) > now }          // 終わった番組は出さない
            error = nil
            searched = true
            var h = history.filter { $0 != q }
            h.insert(q, at: 0)
            historyRaw = h.prefix(10).joined(separator: "\n")
        } catch {
            guard !Task.isCancelled else { return }
            self.error = describeError(error)
            searched = true
        }
        await reserves.refresh()
    }
}
