import SwiftUI
import UIKit

/// 設定 › 診断: いまのビルド・端末、各サーバーにつながるか、直近のログ（エラーだけにも絞れる）。
/// 「まとめてコピー」で全部を 1 つの文章にして貼り付けられる（不具合の報告用）
struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var checks: [Check] = []
    @State private var checking = false
    @State private var errorsOnly = true
    @State private var lines: [String] = []
    @State private var copied = false

    struct Check: Identifiable {
        let id: String
        let name: String
        var ok: Bool?
        var detail: String
        var ms: Int?
    }

    private static let errorWords = ["失敗", "エラー", "できません", "切れ", "crash", "failed", "error", "データ切れ", "例外", "正常に終わっていません"]

    private var shownLines: [String] {
        let l = errorsOnly ? lines.filter { line in Self.errorWords.contains { line.localizedCaseInsensitiveContains($0) } } : lines
        return Array(l.suffix(150).reversed())
    }

    var body: some View {
        NavigationStack {
            List {
                Section("この端末") {
                    row("ビルド", DebugLog.build)
                    row("端末", "\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)")
                    row("メモリ", "\(DebugLog.footprintMB()) MB")
                    row("前回の終わり方", DebugLog.previousSessionCrashed ? "正常に終わっていません（落ちた・強制終了）" : "正常")
                    row("ログの送信", DebugLog.enabled ? "オン（homeserver の chapterd へ）" : "オフ（端末にだけ残す）")
                }
                .listRowBackground(Theme.C.surface)

                Section {
                    ForEach(checks) { c in
                        HStack {
                            Circle().fill(c.ok == nil ? Theme.C.muted : (c.ok! ? Theme.C.live : Theme.C.rec)).frame(width: 8, height: 8)
                            Text(c.name).font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)
                            Spacer()
                            Text(c.detail + (c.ms.map { " · \($0) ms" } ?? ""))
                                .font(Theme.F.caption).foregroundStyle(Theme.C.text3).lineLimit(2).multilineTextAlignment(.trailing)
                        }
                    }
                    Button(checking ? "確かめています…" : "もう一度確かめる") { Task { await runChecks() } }
                        .disabled(checking)
                } header: { Text("サーバー") }
                .listRowBackground(Theme.C.surface)

                Section {
                    Toggle("エラーだけ", isOn: $errorsOnly).tint(Theme.C.accent)
                    if shownLines.isEmpty {
                        Text(errorsOnly ? "エラーはありません" : "ログはまだありません")
                            .font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                    }
                    ForEach(Array(shownLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(Theme.F.mono(11)).foregroundStyle(Theme.C.text2).textSelection(.enabled)
                    }
                } header: { Text("直近のログ（新しい順）") }
                .listRowBackground(Theme.C.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.C.bg)
            .navigationTitle("診断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(copied ? "コピーしました" : "まとめてコピー") {
                        UIPasteboard.general.string = report()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                }
            }
            .refreshable { lines = DebugLog.recent; await runChecks() }
        }
        .preferredColorScheme(.dark)
        .task {
            lines = DebugLog.recent
            await runChecks()
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)
            Spacer()
            Text(v).font(Theme.F.caption).foregroundStyle(Theme.C.text3).multilineTextAlignment(.trailing)
        }
    }

    /// 報告用の文章（ビルド・端末・サーバー・直近のログ 80 行）
    private func report() -> String {
        var s = "MiraTV 診断 \(Date().formatted())\n"
        s += "build \(DebugLog.build) / \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion) / \(DebugLog.footprintMB()) MB"
        s += DebugLog.previousSessionCrashed ? " / 前回は正常終了せず\n" : "\n"
        for c in checks { s += "\(c.ok == true ? "OK" : (c.ok == false ? "NG" : "--")) \(c.name): \(c.detail)\(c.ms.map { " (\($0)ms)" } ?? "")\n" }
        s += "--- log ---\n" + lines.suffix(80).joined(separator: "\n")
        return s
    }

    /// それぞれのサーバーに軽い要求を 1 回送って、つながるか・どれくらいかかるかを見る（並べて同時に）
    private func runChecks() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        var targets: [(String, String, URL?)] = [
            ("mirakurun", "Mirakurun", Servers.mirakurun.map { $0.baseURL.appending(path: "api/version") }),
            ("epgstation", "EPGStation", Servers.epgstation.map { $0.baseURL.appending(path: "api/version") }),
            ("chapterd", "chapterd（CM・字幕）", Servers.chapters.map { $0.baseURL.appending(path: "health") }),
            ("streamd", "streamd（中継・追っかけ）", Servers.streamd.map { $0.appending(path: "health") }),
            ("webbml", "web-bml（データ放送）", Servers.webBML),
        ]
        if let r = UserDefaults.standard.string(forKey: "radioWebURL"), let u = URL(string: r), u.host != nil {
            targets.append(("radio", "radio-web（ラジオ）", u))
        }
        checks = targets.map { Check(id: $0.0, name: $0.1, ok: $0.2 == nil ? nil : nil, detail: $0.2 == nil ? "未設定" : "確かめ中…") }
        await withTaskGroup(of: (String, Bool?, String, Int?).self) { group in
            for (id, _, url) in targets {
                guard let url else { continue }
                group.addTask {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 6
                    let t0 = Date()
                    do {
                        let (_, res) = try await URLSession.shared.data(for: req)
                        let ms = Int(Date().timeIntervalSince(t0) * 1000)
                        let code = (res as? HTTPURLResponse)?.statusCode ?? 0
                        return (id, code < 500, "HTTP \(code)", ms)
                    } catch {
                        return (id, false, describeError(error), nil)
                    }
                }
            }
            for await (id, ok, detail, ms) in group {
                if let i = checks.firstIndex(where: { $0.id == id }) {
                    checks[i].ok = ok; checks[i].detail = detail; checks[i].ms = ms
                }
            }
        }
    }
}
