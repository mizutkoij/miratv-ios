import SwiftUI

/// 字幕の時刻（秒 → 0:12:34）
private func captionClock(_ s: Double) -> String {
    let t = Int(max(s, 0))
    return String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
}

/// 見つかった語を色付きで（ひらがな・カタカナ、全角・半角の違いまでは追わない。完全一致の所だけ）
private func highlighted(_ text: String, _ query: String) -> AttributedString {
    var a = AttributedString(text)
    for w in query.split(whereSeparator: \.isWhitespace) {
        var from = a.startIndex
        while let r = a[from...].range(of: String(w), options: [.caseInsensitive, .widthInsensitive]) {
            a[r].foregroundColor = Theme.C.accent
            a[r].font = Theme.F.jp(14, .bold)
            from = r.upperBound
        }
    }
    return a
}

/// 端末側の照合用: 全角・半角、大文字・小文字、カタカナ・ひらがなを同じに
private func normalizeForSearch(_ s: String) -> String {
    let n = s.precomposedStringWithCompatibilityMapping.lowercased()
    return (n.applyingTransform(.hiraganaToKatakana, reverse: true) ?? n).filter { !$0.isWhitespace }
}

// MARK: - 1 本の録画の字幕（再生画面から）

/// 録画の字幕を文字で一覧にして、絞り込み・タップでその場面へ飛ぶ
struct CaptionTextSheet: View {
    let client: ChapterClient
    let videoFileId: Int
    let filename: String
    let recordedId: Int
    /// 開いたときの再生位置（そこに近い行までスクロールする）
    let position: Double
    let onSeek: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var lines: [CaptionLine] = []
    @State private var status = "字幕を読み込み中…"
    @State private var ready = false
    @State private var query = ""

    private var filtered: [CaptionLine] {
        let words = query.split(whereSeparator: \.isWhitespace).map { normalizeForSearch(String($0)) }
        guard !words.isEmpty else { return lines }
        return lines.filter { l in
            let n = normalizeForSearch(l.text)
            return words.allSatisfy { n.contains($0) }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.C.bg.ignoresSafeArea()
                if !ready {
                    VStack(spacing: 12) {
                        ProgressView().tint(Theme.C.text2)
                        Text(status).font(Theme.F.jp(13)).foregroundStyle(Theme.C.text3).multilineTextAlignment(.center)
                    }
                    .padding(24)
                } else if lines.isEmpty {
                    Text("この録画には字幕がありません").font(Theme.F.jp(14)).foregroundStyle(Theme.C.text3)
                } else {
                    ScrollViewReader { proxy in
                        List(filtered) { line in
                            Button { onSeek(max(line.time - 1, 0)) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(captionClock(line.time)).font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text3)
                                    Text(highlighted(line.text, query)).font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .listRowBackground(Theme.C.bg)
                            .id(line.id)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .onAppear {
                            // いま見ているあたりから
                            if let near = lines.last(where: { $0.time <= position }) { proxy.scrollTo(near.id, anchor: .center) }
                        }
                    }
                }
            }
            .navigationTitle(ready && !lines.isEmpty ? "字幕（\(filtered.count) 行）" : "字幕")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "ことばで絞り込む")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    /// 初回は homeserver が録画を 1 回読んで字幕を取り出す（CPU はほぼ使わない）。終わるまで 3 秒おきに聞く
    private func load() async {
        for _ in 0..<1200 {
            if Task.isCancelled { return }
            do {
                let info = try await client.captions(videoFileId: videoFileId, filename: filename, recordedId: recordedId)
                switch info.status {
                case "ready":
                    lines = info.captions ?? []
                    ready = true
                    return
                case "error":
                    status = "字幕を取り出せませんでした\n\(info.error ?? "")"
                    return
                case "running":
                    status = "字幕を取り出しています… \(Int((info.progress ?? 0) * 100))%\n（録画ファイルを 1 回読むだけです。次からはすぐ出ます）"
                default:
                    status = "順番待ち（CM 検出などが先に動いています）…"
                }
            } catch {
                status = "homeserver（chapterd）に接続できません"
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}

// MARK: - すべての録画から探す（録画タブから）

struct CaptionSearchSheet: View {
    let client: ChapterClient
    let es: EPGStationClient
    /// いま一覧に読み込んである録画（まとめて取り出すときに使う）
    let recordings: [ESRecorded]

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: PlaybackSession
    @State private var query = ""
    @State private var result: CaptionSearchResult?
    @State private var searching = false
    @State private var message: String?
    @State private var batch: (done: Int, total: Int)?
    @State private var batchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.C.bg.ignoresSafeArea()
                List {
                    if let result {
                        if result.results.isEmpty {
                            Text(result.indexed == 0 ? "まだ字幕を取り出した録画がありません。下のボタンで取り出せます。"
                                                     : "見つかりませんでした（\(result.indexed) 本の録画から探しました）")
                                .font(Theme.F.jp(13)).foregroundStyle(Theme.C.text3)
                                .listRowBackground(Theme.C.bg)
                        }
                        ForEach(result.results) { rec in
                            Section {
                                ForEach(rec.hits) { line in
                                    Button { open(rec, at: line.time) } label: {
                                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                                            Text(captionClock(line.time)).font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text3)
                                            Text(highlighted(line.text, query)).font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    .listRowBackground(Theme.C.bg)
                                }
                                if let c = rec.count, c > rec.hits.count {
                                    Text("ほか \(c - rec.hits.count) か所").font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                                        .listRowBackground(Theme.C.bg)
                                }
                            } header: {
                                Text(title(rec)).font(Theme.F.jp(13, .bold)).foregroundStyle(Theme.C.text2).lineLimit(2)
                            }
                        }
                    } else if !searching {
                        Text("録画の字幕から、ことばで場面を探します。スペースで区切ると全部を含む行だけ。ひらがな・カタカナ、全角・半角は区別しません。")
                            .font(Theme.F.jp(13)).foregroundStyle(Theme.C.text3)
                            .listRowBackground(Theme.C.bg)
                    }
                    Section { batchRow } footer: {
                        Text("取り出しは homeserver が録画ファイルを 1 回読むだけ（エンコードなし、録画の邪魔をしない低い優先度）。1 本ずつ順番に進みます。")
                            .font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                    }
                    .listRowBackground(Theme.C.bg)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                if searching { ProgressView().tint(Theme.C.text2) }
            }
            .navigationTitle("字幕で探す")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "せりふ・ことば")
            .onSubmit(of: .search) { Task { await search() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message).font(Theme.F.jp(13)).foregroundStyle(Theme.C.text)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.C.raised, in: Capsule()).padding(.bottom, 20)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { batchTask?.cancel() }
    }

    private var tsRecordings: [(ESRecorded, ESVideoFile, String)] {
        recordings.compactMap { r in
            guard r.isRecording != true, let f = r.videoFiles?.first(where: { $0.type != "encoded" }), let name = f.filename else { return nil }
            return (r, f, name)
        }
    }

    @ViewBuilder private var batchRow: some View {
        if let batch {
            HStack {
                ProgressView(value: Double(batch.done), total: Double(max(batch.total, 1))).tint(Theme.C.accent)
                Text("\(batch.done)/\(batch.total)").font(Theme.F.mono(12)).foregroundStyle(Theme.C.text3)
                Button("やめる") { batchTask?.cancel(); self.batch = nil }.font(Theme.F.jp(13))
            }
        } else {
            Button { startBatch() } label: {
                Label("一覧にある録画 \(tsRecordings.count) 本の字幕を取り出す", systemImage: "text.badge.plus")
                    .font(Theme.F.jp(14, .medium)).foregroundStyle(Theme.C.text)
            }
            .disabled(tsRecordings.isEmpty)
        }
    }

    private func title(_ rec: CaptionSearchResult.Hit) -> String {
        if let rid = rec.rid, let r = recordings.first(where: { $0.id == rid }) { return r.name ?? rec.name ?? "" }
        if let r = recordings.first(where: { $0.videoFiles?.contains { $0.id == rec.id } == true }) { return r.name ?? rec.name ?? "" }
        return rec.name ?? "録画"
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        defer { searching = false }
        do { result = try await client.searchCaptions(q) } catch { flash("homeserver（chapterd）に接続できません") }
    }

    private func open(_ hit: CaptionSearchResult.Hit, at t: Double) {
        Task {
            var rec = recordings.first { r in hit.rid.map { r.id == $0 } ?? (r.videoFiles?.contains { $0.id == hit.id } == true) }
            if rec == nil, let rid = hit.rid { rec = try? await es.recordedItem(id: rid) }
            guard let rec else { flash("この録画は一覧に見つかりません（消されたかもしれません）"); return }
            dismiss()
            session.playRecorded(rec, es: es, at: max(t - 2, 0))
        }
    }

    /// 1 本ずつ順番に頼む（サーバー側も 1 本ずつしか処理しないので、終わるのを待ってから次へ）
    private func startBatch() {
        let items = tsRecordings
        batch = (0, items.count)
        batchTask = Task {
            for (i, (rec, file, name)) in items.enumerated() {
                while !Task.isCancelled {
                    guard let info = try? await client.captions(videoFileId: file.id, filename: name, recordedId: rec.id) else {
                        if Task.isCancelled { return }        // 「やめる」・閉じた
                        flash("homeserver（chapterd）に接続できません"); batch = nil; return
                    }
                    if info.status == "ready" || info.status == "error" { break }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                if Task.isCancelled { return }
                batch = (i + 1, items.count)
            }
            batch = nil
            flash("取り出し終わりました")
            if !query.trimmingCharacters(in: .whitespaces).isEmpty { await search() }
        }
    }

    private func flash(_ s: String) {
        message = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if message == s { message = nil } }
    }
}
