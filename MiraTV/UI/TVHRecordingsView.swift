import SwiftUI

/// 韓国のサーバーの TVHeadend が録画したもの（TVH の DVR）。
/// homeserver の tvh-dvrd（:36205、server/tvh-dvrd.mjs）が一覧と本体を中継する。TVH の認証情報はアプリには持たない。
/// 録画は MPEG-TS なので、再生は録画済みの TS と同じ自前の FFmpeg エンジンで行う（Range で読むのでシークできる）

struct TVHRec: Decodable, Identifiable, Hashable {
    let uuid: String
    let title: String
    let subtitle: String
    let summary: String
    let channel: String
    let start: Double
    let stop: Double
    let size: Int64
    let status: String

    var id: String { uuid }
    var duration: Double { max(stop - start, 0) }
    var startDate: Date { Date(timeIntervalSince1970: start) }
    var watchKey: String { "tvh-\(uuid)" }
}

enum TVHDvr {
    static var baseURL: URL? {
        let s = (UserDefaults.standard.string(forKey: "tvhDvrURL") ?? Defaults.tvhDvrURL)
            .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: s)
    }

    static func list() async throws -> [TVHRec] {
        guard let base = baseURL else { throw URLError(.badURL) }
        var req = URLRequest(url: base.appending(path: "list"))
        req.timeoutInterval = 40
        let (data, res) = try await URLSession.shared.data(for: req)
        if let http = res as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        struct R: Decodable { let items: [TVHRec] }
        return try JSONDecoder().decode(R.self, from: data).items
    }

    static func fileURL(_ rec: TVHRec) -> URL? { baseURL?.appending(path: "file/\(rec.uuid)") }
}

// MARK: - 一覧

struct TVHRecordingsList: View {
    @AppStorage("tvhDvrURL") private var tvhURL = Defaults.tvhDvrURL
    @EnvironmentObject private var session: PlaybackSession
    @State private var items: [TVHRec] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var query = ""
    @State private var channel = ""
    @State private var limit = 60

    private var channels: [String] { Array(Set(items.map(\.channel))).sorted() }
    private var filtered: [TVHRec] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return items.filter { r in
            (channel.isEmpty || r.channel == channel)
                && (q.isEmpty || r.title.localizedCaseInsensitiveContains(q) || r.subtitle.localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("題名で探す", text: $query)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Button("すべての局") { channel = "" }
                    ForEach(channels, id: \.self) { c in Button(c) { channel = c } }
                } label: {
                    Text(channel.isEmpty ? "局" : channel).font(Theme.F.jp(12, .medium)).lineLimit(1)
                        .padding(.horizontal, 10).frame(height: 32)
                        .overlay(Capsule().stroke(Theme.C.borderStrong))
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            if let errorText {
                Text(errorText).font(Theme.F.caption).foregroundStyle(Theme.C.rec)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 6)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    if loading && items.isEmpty { ProgressView().tint(Theme.C.accent).padding(.top, 30) }
                    ForEach(filtered.prefix(limit)) { rec in
                        Button { play(rec) } label: { row(rec) }.buttonStyle(.plain)
                    }
                    if filtered.count > limit {
                        Button { limit += 60 } label: {
                            Text("もっと見る（\(limit)/\(filtered.count)）")
                                .font(Theme.F.jp(13, .medium)).foregroundStyle(Theme.C.text2)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    if !loading && filtered.isEmpty && errorText == nil {
                        Text("録画はありません").font(Theme.F.jp(13)).foregroundStyle(Theme.C.text3).padding(.top, 30)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 16)
            }
            .refreshable { await load() }
        }
        .onChange(of: query) { _, _ in limit = 60 }
        .onChange(of: channel) { _, _ in limit = 60 }
        .task(id: tvhURL) { await load() }
    }

    private func row(_ r: TVHRec) -> some View {
        let saved = WatchPositions.position(key: r.watchKey)
        return VStack(alignment: .leading, spacing: 4) {
            Text(r.title).font(Theme.F.jp(14, .bold)).foregroundStyle(Theme.C.text).lineLimit(2)
            if !r.subtitle.isEmpty {
                Text(r.subtitle).font(Theme.F.caption).foregroundStyle(Theme.C.text2).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text("\(r.channel) · \(r.startDate.formatted(.dateTime.month().day().hour().minute())) · \(Int(r.duration / 60))分")
                    .font(Theme.F.caption).foregroundStyle(Theme.C.text3).lineLimit(1)
                if r.status != "completed" { TagView(text: "録画に乱れ") }
                if saved != nil { TagView(text: "続きから") }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.C.row, in: RoundedRectangle(cornerRadius: Theme.R.card))
    }

    private func play(_ r: TVHRec) {
        guard let url = TVHDvr.fileURL(r) else { return }
        session.playTVH(r, url: url)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await TVHDvr.list()
            errorText = nil
        } catch {
            errorText = "韓国の録画を取得できません: \(describeError(error))"
        }
    }
}

// MARK: - 再生

struct TVHPlayerView: View {
    let rec: TVHRec
    let url: URL

    @StateObject private var engine = PlayerEngine()
    @EnvironmentObject private var radio: RadioPlayer
    @EnvironmentObject private var session: PlaybackSession
    @State private var scrub: Double?
    @State private var showPanel = true
    @State private var resumeAt: Double?
    @State private var lastSaved = Date.distantPast
    private let ticker = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private static let speeds: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    /// TS の長さは読み始めてからでないと分からないので、TVH の予定の長さを仮の値にする
    private var duration: Double { engine.duration > 0 ? engine.duration : rec.duration }

    var body: some View {
        ZStack {
            if session.minimized {
                miniBar
            } else {
                GeometryReader { geo in
                    let landscape = geo.size.width > geo.size.height
                    ZStack {
                        (landscape ? Theme.C.video : Theme.C.bg).ignoresSafeArea()
                        if landscape { landscapeLayout } else { portraitLayout }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!session.minimized)
        .onAppear { start() }
        .onChange(of: engine.isSeekable) { _, ok in
            if ok, let t = resumeAt { resumeAt = nil; engine.seek(to: t) }
        }
        .onReceive(ticker) { _ in saveNow() }
        .onDisappear {
            if resumeAt == nil { saveNow() }
            engine.stop()
            PlaybackSession.requestOrientation(.all)
        }
    }

    private func start() {
        radio.stop()
        engine.durationHint = rec.duration > 0 ? rec.duration : nil
        if let p = WatchPositions.position(key: rec.watchKey), p > 15 { resumeAt = p }
        DebugLog.log("tvh", "再生 \(rec.channel) \(rec.title)")
        engine.play(url: url, file: true)
    }

    private func saveNow() {
        guard engine.position > 0 else { return }
        WatchPositions.save(key: rec.watchKey, position: engine.position, duration: duration)
    }

    // MARK: 見た目

    private var videoStack: some View {
        ZStack {
            Theme.C.video
            VideoSurface(layer: engine.displayLayer)
                .aspectRatio(CGFloat(engine.info.displayAspect), contentMode: .fit)
            switch engine.state {
            case .connecting, .buffering:
                VStack(spacing: 12) {
                    ProgressView().tint(.white).controlSize(.large)
                    Text("韓国のサーバーから読み込んでいます…（初めは数秒かかります）").font(Theme.F.caption).foregroundStyle(Theme.C.text2)
                        .padding(.horizontal, 10).padding(.vertical, 4).background(Color.black.opacity(0.55), in: Capsule())
                }
            case .failed(let msg):
                VStack(spacing: 10) {
                    Text(msg).multilineTextAlignment(.center).font(Theme.F.caption).foregroundStyle(Theme.C.text)
                    Button("もう一度") { resumeAt = engine.position > 15 ? engine.position : resumeAt; engine.play(url: url, file: true) }
                        .buttonStyle(.borderedProminent).tint(Theme.C.accent)
                }
                .padding()
            default:
                EmptyView()
            }
        }
    }

    private func clock(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "--:--" }
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    private var seekSlider: some View {
        Slider(value: Binding(get: { scrub ?? engine.position }, set: { scrub = $0 }), in: 0...max(duration, 1)) { editing in
            if !editing, let s = scrub { engine.seek(to: s); scrub = nil }
        }
        .tint(Theme.C.accent)
        .disabled(!engine.isSeekable)
    }

    private func transport(_ name: String, size: CGFloat = 44, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(filled ? Theme.C.onAccent : Theme.C.text)
                .frame(width: size, height: size)
                .background(filled ? Theme.C.accent : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(Self.speeds, id: \.self) { s in
                Button(s == s.rounded() ? "\(Int(s))x" : String(format: "%.2fx", s)) { engine.setSpeed(s) }
            }
        } label: {
            let r = engine.playbackRate
            Text(r == r.rounded() ? "\(Int(r))x" : String(format: "%.2fx", r)).font(Theme.F.mono(13)).foregroundStyle(Theme.C.text2)
                .padding(.horizontal, 12).frame(height: 32).overlay(Capsule().stroke(Theme.C.borderStrong))
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            seekSlider
            HStack {
                Text(clock(scrub ?? engine.position)).font(Theme.F.mono(12, .medium))
                Spacer()
                Text(clock(duration)).font(Theme.F.mono(12, .medium))
            }
            .foregroundStyle(Theme.C.text3)
            HStack(spacing: 18) {
                transport("gobackward.15") { engine.seek(by: -15) }
                transport(engine.isPaused ? "play.fill" : "pause.fill", size: 54, filled: true) { engine.togglePause() }
                transport("goforward.30") { engine.seek(by: 30) }
                Spacer()
                speedMenu
            }
        }
    }

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                videoStack
                CircleButton(systemName: "chevron.down", size: 36, fill: Color.black.opacity(0.55), foreground: Theme.C.text) { session.minimize() }
                    .padding(12)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    controls.padding(.horizontal, 20).padding(.top, 12)
                    HStack(spacing: 8) {
                        ControlTile(icon: "arrow.up.left.and.arrow.down.right", label: "全画面") {
                            PlaybackSession.requestOrientation(.landscape)
                        }
                    }
                    .padding(.horizontal, 12)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(rec.title).font(Theme.F.jp(17, .bold)).foregroundStyle(Theme.C.text)
                        if !rec.subtitle.isEmpty { Text(rec.subtitle).font(Theme.F.jp(13)).foregroundStyle(Theme.C.text2) }
                        Text("\(rec.channel) · \(rec.startDate.formatted(.dateTime.year().month().day().hour().minute())) · \(Int(rec.duration / 60))分")
                            .font(Theme.F.caption).foregroundStyle(Theme.C.text3)
                        if !rec.summary.isEmpty { Text(rec.summary).font(Theme.F.jp(12)).foregroundStyle(Theme.C.text3) }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 32)
                }
            }
        }
    }

    private var landscapeLayout: some View {
        ZStack {
            videoStack.ignoresSafeArea()
            Color.clear.contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showPanel.toggle() } }
            if showPanel {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        CircleButton(systemName: "arrow.down.right.and.arrow.up.left", fill: Color.black.opacity(0.4), foreground: Theme.C.text) {
                            PlaybackSession.requestOrientation(.portrait)
                        }
                        Text(rec.title).font(Theme.F.jp(17, .bold)).foregroundStyle(Theme.C.text).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8).background(Theme.C.overlayBar)
                    Spacer()
                    HStack(spacing: 10) {
                        transport("gobackward.15", size: 40) { engine.seek(by: -15) }
                        transport(engine.isPaused ? "play.fill" : "pause.fill", size: 44, filled: true) { engine.togglePause() }
                        transport("goforward.30", size: 40) { engine.seek(by: 30) }
                        Text(clock(scrub ?? engine.position)).font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text2)
                        seekSlider
                        Text(clock(duration)).font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text2)
                        speedMenu
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8).background(Theme.C.overlayBar)
                }
            }
        }
    }

    private var miniBar: some View {
        let paused = engine.isPaused
        return MiniPlayerBar(
            title: rec.title,
            subtitle: "\(rec.channel) · \(clock(engine.position)) / \(clock(duration))",
            video: { VideoSurface(layer: engine.displayLayer) },
            trailing: {
                Button { engine.togglePause() } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.C.text).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            },
            onExpand: { session.expand() },
            onClose: { session.close() })
    }
}
