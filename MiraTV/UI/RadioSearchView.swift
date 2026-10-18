import SwiftUI

/// ラジオの過去番組を探す（約 50 万件）。検索はサーバー（radio-search）が全文検索で行い、50 件ずつ受け取る
struct RadioSearchView: View {
    let stations: [RadioStation]
    @EnvironmentObject private var radio: RadioPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var playableOnly = true
    @State private var newestFirst = true
    @State private var station: String?
    @State private var stationChoices: [RadioSearchStation] = []
    @State private var hits: [RadioSearchHit] = []
    @State private var total = 0
    @State private var capped = false
    @State private var loading = false
    @State private var errorText: String?
    @State private var searchTask: Task<Void, Never>?

    private let pageSize = 50
    private var client: RadioSearchClient? { Servers.radioSearch }

    private func name(_ id: String) -> String {
        stations.first { $0.source == .radiko && $0.id == id }?.name ?? id
    }

    var body: some View {
        ZStack {
            Theme.C.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                searchField
                filters
                resultLine
                results
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { RadioMiniPlayer() }
        .task { reload(debounce: false) }
        .onChange(of: query) { _, _ in reload(debounce: true) }
        .onChange(of: playableOnly) { _, _ in reload(debounce: false) }
        .onChange(of: newestFirst) { _, _ in reload(debounce: false) }
        .onChange(of: station) { _, _ in reload(debounce: false) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            CircleButton(systemName: "chevron.left") { dismiss() }
            Text("過去の番組を探す").font(Theme.F.jp(18, .bold)).foregroundStyle(Theme.C.text)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.C.text4)
            TextField("番組名・出演者（空なら新着順）", text: $query)
                .font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.C.text4) }
            }
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(Theme.C.surface, in: RoundedRectangle(cornerRadius: Theme.R.button))
        .padding(.horizontal, 12)
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ChipView(label: "聴けるものだけ", selected: playableOnly) { playableOnly.toggle() }
                ChipView(label: newestFirst ? "新しい順" : "古い順", selected: false) { newestFirst.toggle() }
                Menu {
                    Button("すべての局") { station = nil }
                    ForEach(stationChoices.prefix(60), id: \.id) { c in
                        Button("\(name(c.id))（\(c.count)）") { station = c.id }
                    }
                } label: {
                    Text(station.map(name) ?? "局で絞る")
                        .font(Theme.F.jp(13, station == nil ? .medium : .bold))
                        .padding(.horizontal, 12).frame(minHeight: 32)
                        .foregroundStyle(station == nil ? Theme.C.text2 : Theme.C.onAccent)
                        .background(station == nil ? Theme.C.surface : Theme.C.accent, in: Capsule())
                        .overlay(Capsule().stroke(station == nil ? Theme.C.border : Color.clear))
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 10)
    }

    private var resultLine: some View {
        HStack {
            if let errorText {
                Text(errorText).font(Theme.F.caption).foregroundStyle(Theme.C.rec).lineLimit(3)
            } else {
                Text(loading && hits.isEmpty ? "検索中…" : "\(total.formatted())\(capped ? "+" : "") 件")
                    .font(Theme.F.caption).foregroundStyle(Theme.C.text3)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.bottom, 6)
    }

    private var results: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(hits) { h in
                    row(h)
                        .onAppear { if h.id == hits.last?.id { loadMore() } }
                }
                if hits.isEmpty && !loading && errorText == nil {
                    Text(playableOnly ? "聴ける番組が見つかりません。「聴けるものだけ」を外すと、再生できない古い番組も出ます" : "見つかりません")
                        .font(Theme.F.caption).foregroundStyle(Theme.C.muted).padding(.top, 24)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 16)
        }
    }

    private func row(_ h: RadioSearchHit) -> some View {
        Button {
            guard h.playable else { return }
            radio.playArchive(h.scheduleItem, stationName: name(h.station))
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(h.title).font(Theme.F.rowTitle).foregroundStyle(h.playable ? Theme.C.text : Theme.C.muted).lineLimit(2)
                    Text("\(name(h.station)) · \(h.dateText)\(h.pfm.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? "")")
                        .font(Theme.F.caption).foregroundStyle(Theme.C.text3).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(h.playable ? "▶" : "未収録").font(Theme.F.jp(12, .medium))
                    .foregroundStyle(h.playable ? Theme.C.accent : Theme.C.muted)
            }
            .rowCard()
        }
        .buttonStyle(.plain)
        .disabled(!h.playable)
    }

    // MARK: 検索

    private func reload(debounce: Bool) {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            if debounce { try? await Task.sleep(nanoseconds: 350_000_000) }
            if Task.isCancelled { return }
            guard let client else { errorText = "ラジオ検索の URL が不正です（設定で確認）"; return }
            loading = true
            defer { loading = false }
            do {
                async let page = client.search(q: query, station: station, playableOnly: playableOnly, newestFirst: newestFirst,
                                               limit: pageSize, offset: 0)
                async let choices = client.stations(q: query, playableOnly: playableOnly)
                let r = try await page
                if Task.isCancelled { return }
                hits = r.items; total = r.total; capped = r.totalCapped ?? false; errorText = nil
                if let c = try? await choices { stationChoices = c }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                errorText = describeError(error)
            }
        }
    }

    private func loadMore() {
        guard !loading, hits.count < total, let client else { return }
        let offset = hits.count
        loading = true
        Task { @MainActor in
            defer { loading = false }
            guard let r = try? await client.search(q: query, station: station, playableOnly: playableOnly, newestFirst: newestFirst,
                                                    limit: pageSize, offset: offset) else { return }
            let known = Set(hits.map(\.id))
            hits += r.items.filter { !known.contains($0.id) }
        }
    }
}
