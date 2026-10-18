import SwiftUI
import AVKit

/// Usenet のアーカイブ（VPS1 の nzb-dl）の再生。docs/nzb-stream-playback.md
///
/// - 本体が .ts: 自前の FFmpeg エンジン（録画と同じ。Range で読むのでシーク・字幕・PiP が使える）
/// - 本体が .mp4: AVPlayer（配信サービス由来の録画。字幕・データ放送は無い）
/// - 本体が .7z: 2026-09-18 より前の暗号化アーカイブ。丸ごと取らないと読めないので再生しない
///
/// nzb-dl は初めて触る位置を Usenet から取るので、開いた直後とシーク直後は 1〜3 秒（数回測り直すと十数秒）かかる。
/// 本命が読めなかったときは、同じ放送の再投稿 [reupload-N] に自動で切り替える。
struct UsenetPlayerView: View {
    let entry: UsenetEntry
    let client: NzbDlClient

    enum Mode: Equatable {
        case preparing
        case ts
        case mp4
        case unavailable(String)
    }

    @StateObject private var engine = PlayerEngine()
    @StateObject private var captions = CaptionController()
    @EnvironmentObject private var radio: RadioPlayer
    @EnvironmentObject private var session: PlaybackSession

    @State private var mode: Mode = .preparing
    /// いま読んでいる item（本命、または再投稿）
    @State private var current: NzbItemRaw?
    /// 試した item の id（再投稿へ切り替えるとき、同じものをもう一度試さないように）
    @State private var tried: [String] = []
    /// 一度でも再生に入ったか（入る前の失敗なら、再投稿へ自動で切り替える）
    @State private var everPlayed = false
    @State private var startTask: Task<Void, Never>?

    @State private var avPlayer: AVPlayer?
    @State private var mp4Paused = false
    @State private var captionsOn = false
    @State private var showPanel = true
    @State private var scrub: Double?
    /// シークできるようになったらこの位置へ飛ぶ（続きから・もう一度）
    @State private var resumeAt: Double?
    @State private var resumedFrom: Double?
    @State private var toast: String?
    @State private var nowPlaying = TVNowPlaying()
    @State private var lastSaved = Date.distantPast
    private let clockTicker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private static let speeds: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        ZStack {
            if session.minimized {
                miniBar
            } else if mode == .mp4 {
                mp4Layout
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
        .onChange(of: engine.state) { _, s in handleStateChange(s) }
        .onChange(of: engine.isSeekable) { _, ok in
            if mode == .ts { updateNowPlaying() }
            if ok, let t = resumeAt { resumeAt = nil; engine.seek(to: t) }
        }
        .onChange(of: engine.isPaused) { _, _ in if mode == .ts { updateNowPlaying() } }
        .onReceive(clockTicker) { _ in onClockTick() }
        .onDisappear {
            // 続きからの位置へまだ飛んでいない（開いてすぐ閉じた）ときは、前の位置を消さない
            if resumeAt == nil && currentPosition > 0 {
                WatchPositions.save(key: entry.watchKey, position: currentPosition, duration: currentDuration)
            }
            startTask?.cancel()
            nowPlaying.deactivate()
            engine.stop()
            avPlayer?.pause()
            requestOrientation(.all)
        }
    }

    // MARK: - 開く

    private func start() {
        radio.stop()
        engine.captionHandler = { packets in
            if captionsOn { captions.feed(packets) }
        }
        let saved = WatchPositions.position(key: entry.watchKey)
        if let saved { resumedFrom = saved; showToast("続きから再生（\(clock(saved))）") }
        open(entry.primary, resume: saved)
    }

    /// 本体ファイルの種類を確かめてから、合うエンジンで開く
    private func open(_ item: NzbItemRaw, resume: Double?) {
        current = item
        tried.append(item.id)
        everPlayed = false
        mode = .preparing
        startTask?.cancel()
        startTask = Task { @MainActor in
            let ext = await mainExt(of: item)
            if Task.isCancelled { return }
            DebugLog.log("nzb", "再生 id=\(item.id) ext=\(ext ?? "?") \(item.name)")
            switch ext ?? "" {
            case "7z", "rar", "zip":
                // 再投稿が別の形式で上がっていることもあるので、あればそちらを試す
                if let next = untriedAlternates.first {
                    showToast("暗号化アーカイブのため、再投稿で再生します")
                    open(next, resume: resume)
                } else {
                    mode = .unavailable("この番組は暗号化された .\(ext ?? "") で投稿されているため、ストリーム再生できません（2026-09-18 より前の投稿）")
                }
            case "mp4", "m4v", "mov":
                playMP4(item, resume: resume)
            default:
                // ts / m2ts / 分からないとき（libavformat が中身を見て判断する）
                playTS(item, resume: resume)
            }
        }
    }

    /// 本体の拡張子。一度調べたものは覚えておく。調べられなければ nil
    private func mainExt(of item: NzbItemRaw) async -> String? {
        if let e = UsenetCatalog.shared.mainExt(item.id) { return e }
        guard let files = try? await client.files(itemName: item.name),
              let main = NzbDlClient.mainFile(files) else { return nil }
        let ext = main.ext
        if !ext.isEmpty { UsenetCatalog.shared.setMainExt(ext, for: item.id) }
        return ext.isEmpty ? nil : ext
    }

    private func playTS(_ item: NzbItemRaw, resume: Double?) {
        mode = .ts
        if let resume { resumeAt = resume }
        nowPlaying.activate(onPlay: { engine.setPaused(false); updateNowPlaying() },
                            onPause: { engine.setPaused(true); updateNowPlaying() },
                            onSkip: { engine.seek(by: $0); updateNowPlaying() })
        // 長さは libavformat が末尾の PTS から出す。出せなかったときだけ、放送の TS（約 16Mbps）として大きさから見積もる
        // （大きさは par2 込みなので少し長めに出る）
        engine.durationHint = item.bytes > 0 ? Double(item.bytes) * 8 / 16_000_000 : nil
        engine.play(url: client.streamURL(id: item.id), file: true)
    }

    private func playMP4(_ item: NzbItemRaw, resume: Double?) {
        mode = .mp4
        engine.stop()
        // /api/stream/<id> には拡張子が無いので、AVPlayer に中身の種類を教える
        let asset = AVURLAsset(url: client.streamURL(id: item.id),
                               options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
        let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        avPlayer = p
        mp4Paused = false
        if let resume { p.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) }
        p.play()
    }

    private var untriedAlternates: [NzbItemRaw] {
        entry.alternates.filter { !tried.contains($0.id) }
    }

    private func handleStateChange(_ s: PlayerEngine.State) {
        switch s {
        case .playing:
            everPlayed = true
        case .failed(let msg):
            // 再生に入る前に読めなかった（記事が欠けている等）→ 再投稿があれば自動で切り替える
            guard !everPlayed, let next = untriedAlternates.first else { return }
            DebugLog.log("nzb", "読めなかったので再投稿へ id=\(current?.id ?? "?") → \(next.id): \(msg)")
            showToast("読み込めなかったので、再投稿で再生します")
            open(next, resume: resumeAt ?? resumedFrom)
        default:
            break
        }
    }

    private func retry() {
        guard let current else { return }
        let pos = engine.position
        if mode == .ts {
            engine.play(url: client.streamURL(id: current.id), file: true)
            if pos > 5 { resumeAt = pos }
        } else {
            open(current, resume: pos > 5 ? pos : nil)
        }
    }

    private func switchToAlternate() {
        guard let next = untriedAlternates.first else { return }
        let pos = currentPosition
        avPlayer?.pause(); avPlayer = nil
        open(next, resume: pos > 5 ? pos : (resumeAt ?? resumedFrom))
    }

    // MARK: - 位置・ロック画面

    private var currentPosition: Double {
        if mode == .mp4 { return avPlayer?.currentTime().seconds ?? 0 }
        return engine.position
    }

    private var currentDuration: Double {
        if mode == .mp4, let d = avPlayer?.currentItem?.duration.seconds, d.isFinite { return d }
        return engine.duration
    }

    /// 0.25 秒ごと: 5 秒ごとに位置を保存・ロック画面の表示・mp4 の失敗の検出
    private func onClockTick() {
        if mode == .mp4, let item = avPlayer?.currentItem, item.status == .failed {
            let msg = item.error.map { describeError($0) } ?? "再生できませんでした"
            DebugLog.log("nzb", "mp4 の再生に失敗 id=\(current?.id ?? "?"): \(msg)")
            avPlayer?.pause(); avPlayer = nil
            if let next = untriedAlternates.first {
                showToast("読み込めなかったので、再投稿で再生します")
                open(next, resume: resumedFrom)
            } else {
                mode = .unavailable("再生できませんでした\n\(msg)")
            }
            return
        }
        let pos = currentPosition
        guard pos.isFinite, pos > 0 else { return }
        if Date().timeIntervalSince(lastSaved) > 5 {
            lastSaved = Date()
            WatchPositions.save(key: entry.watchKey, position: pos, duration: currentDuration)
            if mode == .ts { updateNowPlaying() }
        }
    }

    private func updateNowPlaying() {
        nowPlaying.update(title: entry.title, channel: entry.station.isEmpty ? "アーカイブ" : entry.station,
                          artworkURL: nil, isLive: false,
                          position: engine.position, duration: currentDuration,
                          rate: engine.isPaused ? 0 : engine.playbackRate)
    }

    private func restartFromBeginning() {
        resumedFrom = nil
        WatchPositions.save(key: entry.watchKey, position: 0, duration: currentDuration)
        if mode == .mp4 { avPlayer?.seek(to: .zero) } else { resumeAt = nil; engine.seek(to: 0) }
    }

    private func capture() {
        guard let img = engine.captureImage() else { showToast("まだ映像がありません"); return }
        Task { showToast(await CaptureSaver.save(img)) }
    }

    private func toggleCaptions() {
        captionsOn.toggle()
        if !captionsOn { captions.clear() }
    }

    // MARK: - 表示の部品

    private var airText: String {
        guard let d = entry.airDate else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yyyy/M/d(E) HH:mm"
        return f.string(from: d)
    }

    private var sizeText: String {
        entry.bytes > 0 ? ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file) : ""
    }

    private var videoStack: some View {
        ZStack {
            Theme.C.video
            VideoSurface(layer: engine.displayLayer)
                .aspectRatio(engine.info.displayAspect, contentMode: .fit)
            CaptionOverlay(controller: captions)
                .aspectRatio(engine.info.displayAspect, contentMode: .fit)
                .opacity(captionsOn ? 1 : 0)
                .allowsHitTesting(false)
            stateOverlay
            toastLayer
        }
    }

    @ViewBuilder private var stateOverlay: some View {
        switch mode {
        case .preparing:
            loading("Usenet の投稿を確認しています…")
        case .unavailable(let msg):
            VStack(spacing: 10) {
                Image(systemName: "lock.fill").font(.system(size: 28)).foregroundStyle(Theme.C.muted)
                Text(msg).multilineTextAlignment(.center).font(Theme.F.caption).foregroundStyle(Theme.C.text)
            }
            .padding(24)
        case .mp4:
            EmptyView()
        case .ts:
            switch engine.state {
            case .connecting, .buffering:
                loading(engine.position > 0 ? "読み込み中…（初めて見る位置は数秒かかります）" : "Usenet から読み込んでいます…")
            case .failed(let msg):
                VStack(spacing: 10) {
                    Text(msg).multilineTextAlignment(.center).font(Theme.F.caption).foregroundStyle(Theme.C.text)
                    HStack(spacing: 10) {
                        Button("もう一度") { retry() }
                            .buttonStyle(.borderedProminent).tint(Theme.C.accent)
                        if !untriedAlternates.isEmpty {
                            Button("再投稿で再生") { switchToAlternate() }
                                .buttonStyle(.bordered).tint(Theme.C.text)
                        }
                    }
                }
                .padding()
            default:
                if engine.reachedEnd {
                    Button { engine.seek(to: 0) } label: {
                        Label("最初から再生", systemImage: "gobackward")
                            .font(Theme.F.jp(14, .bold)).foregroundStyle(Theme.C.onAccent)
                            .padding(.horizontal, 16).frame(height: 44)
                            .background(Theme.C.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func loading(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white).controlSize(.large)
            Text(text).font(Theme.F.caption).foregroundStyle(Theme.C.text2)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.black.opacity(0.55), in: Capsule())
        }
    }

    @ViewBuilder private var toastLayer: some View {
        if let toast {
            HStack(spacing: 10) {
                Text(toast).font(Theme.F.jp(13, .bold)).foregroundStyle(Theme.C.text)
                if resumedFrom != nil, toast.hasPrefix("続きから") {
                    Button("最初から") { restartFromBeginning(); withAnimation { self.toast = nil } }
                        .font(Theme.F.jp(13, .bold)).foregroundStyle(Theme.C.accent)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.black.opacity(0.75), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 12)
            .transition(.opacity)
        }
    }

    private func showToast(_ s: String, seconds: Double = 4) {
        withAnimation { toast = s }
        let shown = s
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { if toast == shown { withAnimation { toast = nil } } }
    }

    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let t = Int(seconds)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    private var speedLabel: String {
        let r = engine.playbackRate
        return r == r.rounded() ? "\(Int(r))x" : String(format: "%.2gx", r)
    }

    private var sliderBinding: Binding<Double> {
        Binding(get: { scrub ?? engine.position }, set: { scrub = $0 })
    }

    /// シークは指を離したときだけ（つまみを動かすたびに Usenet を読みに行かないように）
    private func commitScrub() {
        if let s = scrub { resumedFrom = nil; engine.seek(to: s); scrub = nil }
    }

    private var seekSlider: some View {
        Slider(value: sliderBinding, in: 0...max(engine.duration, 1)) { editing in
            if !editing { commitScrub() }
        }
        .tint(Theme.C.accent)
        .disabled(!engine.isSeekable)
    }

    private func transportButton(_ systemName: String, size: CGFloat = 44, filled: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(filled ? Theme.C.onAccent : Theme.C.text)
                .frame(width: size, height: size)
                .background(filled ? Theme.C.accent : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!engine.isSeekable && systemName != "pause.fill" && systemName != "play.fill")
    }

    private var speedMenu: some View {
        Menu {
            ForEach(Self.speeds, id: \.self) { s in
                Button(s == s.rounded() ? "\(Int(s))x" : String(format: "%.2fx", s)) { engine.setSpeed(s) }
            }
        } label: {
            Text(speedLabel).font(Theme.F.mono(13)).foregroundStyle(Theme.C.text2)
                .padding(.horizontal, 12).frame(height: 32)
                .overlay(Capsule().stroke(Theme.C.borderStrong))
        }
    }

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.title).font(Theme.F.programTitle).foregroundStyle(Theme.C.text).lineSpacing(4)
            Text([entry.station, airText].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(Theme.F.jp(13)).foregroundStyle(Theme.C.text3)
            HStack(spacing: 6) {
                TagView(text: "Usenet")
                TagView(text: mode == .mp4 ? "MP4" : "TS")
                ForEach(entry.flags, id: \.self) { TagView(text: $0) }
                if !entry.alternates.isEmpty { TagView(text: "再投稿 \(entry.alternates.count)") }
            }
            Text(statusText).font(Theme.F.caption).foregroundStyle(Theme.C.text4)
        }
    }

    private var statusText: String {
        var parts: [String] = []
        if !sizeText.isEmpty { parts.append(sizeText) }
        switch mode {
        case .ts: parts.append(engine.isSeekable ? "シーク可（初めての位置は数秒）" : "シーク準備中…")
        case .mp4: parts.append("標準のコントロールでシーク可 · 字幕なし")
        default: break
        }
        if let c = current, c.id != entry.id { parts.append("再投稿を再生中") }
        return parts.joined(separator: " · ")
    }

    // MARK: - ミニプレイヤー

    private var miniBar: some View {
        let paused = mode == .mp4 ? mp4Paused : engine.isPaused
        return MiniPlayerBar(
            title: entry.title,
            subtitle: mode == .mp4 ? "アーカイブ · MP4" : "アーカイブ · \(clock(engine.position)) / \(clock(engine.duration))",
            video: {
                if mode == .mp4 {
                    if let avPlayer { PlayerLayerSurface(player: avPlayer) }
                } else {
                    VideoSurface(layer: engine.displayLayer)
                }
            },
            trailing: {
                Button {
                    if mode == .mp4 {
                        guard let p = avPlayer else { return }
                        if p.rate == 0 { p.play(); mp4Paused = false } else { p.pause(); mp4Paused = true }
                    } else {
                        engine.togglePause()
                    }
                } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.C.text).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(paused ? "再生" : "一時停止")
            },
            onExpand: { session.expand() },
            onClose: { session.close() })
    }

    // MARK: - 縦

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                videoStack
                CircleButton(systemName: "chevron.down", size: 36, fill: Color.black.opacity(0.55),
                             foreground: Theme.C.text) { session.minimize() }
                    .padding(12)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(spacing: 8) {
                        seekSlider
                        HStack {
                            Text(clock(scrub ?? engine.position)).font(Theme.F.mono(12, .medium))
                            Spacer()
                            Text(clock(engine.duration)).font(Theme.F.mono(12, .medium))
                        }
                        .foregroundStyle(Theme.C.text3)
                        HStack(spacing: 18) {
                            transportButton("gobackward.15") { engine.seek(by: -15) }
                            transportButton(engine.isPaused ? "play.fill" : "pause.fill", size: 54, filled: true) {
                                engine.togglePause()
                            }
                            transportButton("goforward.30") { engine.seek(by: 30) }
                            Spacer()
                            speedMenu
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 12)

                    HStack(spacing: 8) {
                        ControlTile(icon: "captions.bubble", label: "字幕", enabled: engine.info.hasCaption,
                                    active: captionsOn) { toggleCaptions() }
                        ControlTile(icon: "camera", label: "写真") { capture() }
                        PiPTile(pip: engine.pip, supported: true)
                        ControlTile(icon: "arrow.up.left.and.arrow.down.right", label: "全画面") { requestOrientation(.landscape) }
                    }
                    .padding(.horizontal, 12)

                    infoBlock
                        .padding(.horizontal, 20).padding(.bottom, 32)
                }
            }
        }
    }

    // MARK: - 横（全画面）

    private var landscapeLayout: some View {
        ZStack {
            videoStack.ignoresSafeArea()
            Color.clear.contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showPanel.toggle() } }
            if showPanel {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        CircleButton(systemName: "arrow.down.right.and.arrow.up.left", fill: Color.black.opacity(0.4),
                                     foreground: Theme.C.text) { requestOrientation(.portrait) }
                        Text(entry.title).font(Theme.F.jp(17, .bold)).foregroundStyle(Theme.C.text).lineLimit(1)
                        Spacer()
                        CapsuleTile(label: "字幕", enabled: engine.info.hasCaption, active: captionsOn) { toggleCaptions() }
                        CapsuleTile(label: "写真") { capture() }
                        PiPCapsule(pip: engine.pip, supported: true)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.C.overlayBar)

                    Spacer()

                    HStack(spacing: 10) {
                        transportButton("gobackward.15", size: 40) { engine.seek(by: -15) }
                        transportButton(engine.isPaused ? "play.fill" : "pause.fill", size: 44, filled: true) {
                            engine.togglePause()
                        }
                        transportButton("goforward.30", size: 40) { engine.seek(by: 30) }
                        Text(clock(scrub ?? engine.position)).font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text2)
                        seekSlider
                        Text(clock(engine.duration)).font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text2)
                        speedMenu
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.C.overlayBar)
                }
            }
        }
    }

    // MARK: - mp4（AVPlayer）

    private var mp4Layout: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Theme.C.video
                if let avPlayer { SystemPlayerView(player: avPlayer) }
                toastLayer
                CircleButton(systemName: "chevron.down", size: 36, fill: Color.black.opacity(0.55),
                             foreground: Theme.C.text) { session.minimize() }
                    .padding(12)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            ScrollView {
                infoBlock.padding(20)
            }
        }
        .background(Theme.C.bg.ignoresSafeArea())
    }
}
