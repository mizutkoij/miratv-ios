import SwiftUI

/// 設定（DESIGN.md では未デザイン）: 接続先の URL、接続テスト、一覧の表示設定
struct SettingsView: View {
    @AppStorage("mirakurunURL") private var mirakurunURL = Defaults.mirakurunURL
    @AppStorage("epgstationURL") private var epgstationURL = Defaults.epgstationURL
    @AppStorage("radioWebURL") private var radioURL = Defaults.radioWebURL
    @AppStorage("webbmlURL") private var webbmlURL = Defaults.webbmlURL
    @AppStorage("chapterURL") private var chapterURL = Defaults.chapterURL
    @AppStorage("autoSkipCM") private var autoSkipCM = false
    @AppStorage("showInactiveChannels") private var showInactive = false
    @AppStorage("debugLog") private var debugLog = true
    /// EPGStation に変換（ffmpeg のエンコード）をさせる再生モードを使うか。サーバーの CPU を大きく使うので既定はオフ
    @AppStorage("allowServerTranscode") private var allowTranscode = false
    @AppStorage("cmDetection") private var cmDetection = true

    @EnvironmentObject private var epg: EPGStore

    @State private var results: [String: (ok: Bool, text: String)] = [:]
    @State private var testing = false

    var body: some View {
        ZStack {
            Theme.C.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "設定", status: nil) { EmptyView() }
                        .padding(.horizontal, -20)

                    field("Mirakurun（テレビの映像・局一覧）", $mirakurunURL, Defaults.mirakurunURL, key: "mirakurun")
                    field("EPGStation（番組表・録画・変換配信）", $epgstationURL, Defaults.epgstationURL, key: "epgstation")
                    field("radio-web（ラジオ）", $radioURL, Defaults.radioWebURL, key: "radio")
                    field("web-bml（データ放送）", $webbmlURL, Defaults.webbmlURL, key: "webbml",
                          hint: "homeserver の Docker コンテナで動いています。空にすると「データ」ボタンは使えません。")
                    field("CM 検出（録画のチャプター）", $chapterURL, Defaults.chapterURL, key: "chapter",
                          hint: "録画を開くと、homeserver が音声の無音位置から CM の区間を推定します（初回は 1 時間の番組で約 1 分）。")

                    Button { Task { await runTests() } } label: {
                        Text(testing ? "確認中…" : "接続テスト")
                            .font(Theme.F.jp(15, .bold)).foregroundStyle(Theme.C.onAccent)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Theme.C.accent, in: RoundedRectangle(cornerRadius: Theme.R.button))
                    }
                    .buttonStyle(.plain)
                    .disabled(testing)

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("サーバーで変換する再生モードを使う", isOn: $allowTranscode)
                            .tint(Theme.C.accent)
                            .font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)
                        Text("オフ（おすすめ）: テレビも録画も、元の TS をそのまま受け取って端末でデコードします。EPGStation に変換をさせないので、サーバーの負荷はほぼ配信だけです。オンにすると再生モードに「高画質変換・省データ・変換（TS）」が出ますが、見ている間 EPGStation が ffmpeg でエンコードし続けます。")
                            .font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("録画の CM を検出する", isOn: $cmDetection)
                            .tint(Theme.C.accent)
                            .font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)
                        Text("録画を開くと homeserver が音声だけを読んで無音の位置を調べます（エンコードはしません。1 時間の番組で約 1 分、1 回だけ）。")
                            .font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                    }

                    Toggle("録画の CM を自動でスキップ", isOn: $autoSkipCM)
                        .tint(Theme.C.accent)
                        .font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)
                        .disabled(!cmDetection)

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("デバッグログを送る", isOn: $debugLog)
                            .tint(Theme.C.accent)
                            .font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)
                        Text("不具合調査用。動作の記録（状態・メモリ・固まった時間）を CM 検出サービス経由で homeserver に送ります。ビルド \(DebugLog.build)")
                            .font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("放送していない局も一覧に出す", isOn: $showInactive)
                            .tint(Theme.C.accent)
                            .font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)
                        Text("EPGStation が把握している局だけを表示します（放送していない副チャンネルやワンセグを隠します）。")
                            .font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                    }

                    Text("外出先からは Tailscale の IP（100.x）を指定してください。これらのサーバーは認証がないので、Tailscale の外には公開しないでください。")
                        .font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
    }

    private func field(_ title: String, _ text: Binding<String>, _ placeholder: String, key: String,
                       hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.F.section).foregroundStyle(Theme.C.text)
            TextField(placeholder, text: text)
                .font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, 12).frame(height: 44)
                .background(Theme.C.surface, in: RoundedRectangle(cornerRadius: Theme.R.button))
                .overlay(RoundedRectangle(cornerRadius: Theme.R.button).stroke(Theme.C.border))
            if let hint { Text(hint).font(Theme.F.caption).foregroundStyle(Theme.C.text4) }
            if let r = results[key] { StatusLine(text: r.text, color: r.ok ? Theme.C.live : Theme.C.rec) }
        }
    }

    private func runTests() async {
        testing = true
        defer { testing = false }
        results = [:]

        if let c = MirakurunClient(mirakurunURL) {
            do { results["mirakurun"] = (true, "接続できました · \(try await c.services().count) サービス") }
            catch { results["mirakurun"] = (false, describeError(error)) }
        } else { results["mirakurun"] = (false, "URL が不正です") }

        if let c = EPGStationClient(epgstationURL) {
            do {
                let now = Date()
                let n = try await c.schedules(from: now, to: now.addingTimeInterval(3600)).count
                results["epgstation"] = (true, "接続できました · 放送中の \(n) 局")
            } catch { results["epgstation"] = (false, describeError(error)) }
        } else { results["epgstation"] = (false, "URL が不正です") }

        if let c = RadioWebClient(radioURL) {
            do { results["radio"] = (true, "接続できました · \(try await c.stations().stations.count) 局") }
            catch { results["radio"] = (false, describeError(error)) }
        } else { results["radio"] = (false, "URL が不正です") }

        if let c = ChapterClient(chapterURL) {
            do {
                var req = URLRequest(url: c.baseURL.appending(path: "health"))
                req.timeoutInterval = 10
                let (_, res) = try await URLSession.shared.data(for: req)
                let code = (res as? HTTPURLResponse)?.statusCode ?? 0
                results["chapter"] = (code < 400, code < 400 ? "接続できました" : "HTTP \(code)")
            } catch { results["chapter"] = (false, describeError(error)) }
        } else { results["chapter"] = (false, "未設定（CM の検出は使えません）") }

        let bml = webbmlURL.trimmingCharacters(in: .whitespaces)
        if bml.isEmpty {
            results["webbml"] = (false, "未設定（データ放送は使えません）")
        } else if let u = URL(string: bml), u.host != nil {
            do {
                var req = URLRequest(url: u)
                req.timeoutInterval = 10
                let (_, res) = try await URLSession.shared.data(for: req)
                let code = (res as? HTTPURLResponse)?.statusCode ?? 0
                results["webbml"] = (code < 400, code < 400 ? "接続できました" : "HTTP \(code)")
            } catch { results["webbml"] = (false, describeError(error)) }
        } else { results["webbml"] = (false, "URL が不正です") }
    }
}

/// 第 2 弾以降で実装する画面の仮置き
struct PlaceholderView: View {
    let title: String
    let icon: String
    let note: String

    var body: some View {
        ZStack {
            Theme.C.bg.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 40)).foregroundStyle(Theme.C.muted)
                Text(title).font(Theme.F.screenTitle).foregroundStyle(Theme.C.text)
                Text(note).font(Theme.F.meta).foregroundStyle(Theme.C.text3).multilineTextAlignment(.center)
            }
            .padding(32)
        }
    }
}
