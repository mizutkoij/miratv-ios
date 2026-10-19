import SwiftUI
import AVKit

/// 録画の再生。
/// - TS: 自前の FFmpeg エンジン。シークバー・一時停止・±スキップ・再生速度・全画面・字幕・データ放送に対応
///   （位置と長さ、シークの仕組みは TvtPlay を手本にした: docs/tvtplay-analysis.md）
/// - 変換済み mp4: AVPlayer（標準のコントロール）。データ放送は入っていない
struct RecordedPlayerView: View {
    let recorded: ESRecorded
    let es: EPGStationClient

    @StateObject private var engine = PlayerEngine()
    @StateObject private var bml = BMLController()
    @StateObject private var captions = CaptionController()
    @EnvironmentObject private var radio: RadioPlayer
    @EnvironmentObject private var session: PlaybackSession
    @EnvironmentObject private var epg: EPGStore
    @StateObject private var comments = CommentController()
    @AppStorage("showComments") private var commentsOn = false
    @State private var nowPlaying = TVNowPlaying()
    @State private var toast: String?
    /// 「続きから」で開いたときの位置（「最初から」ボタンを出すため）
    @State private var resumedFrom: Double?
    private let clockTicker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    @State private var lastSaved = Date.distantPast

    @State private var avPlayer: AVPlayer?
    @State private var dataMode = false
    @State private var captionsOn = false
    @State private var showPanel = true
    @State private var scrub: Double?
    @AppStorage("autoSkipCM") private var autoSkipCM = false
    @AppStorage("cmDetection") private var cmDetection = true
    /// homeserver の CM 検出サービスが無音位置から推定した CM ブロック（秒）
    @State private var cmBlocks: [(start: Double, end: Double)] = []
    @State private var cmStatus = ""
    /// 自動スキップしたブロックの開始。同じブロックで繰り返さない（自分で戻ったときに飛ばされ続けないように）
    @State private var autoSkipped: Double?
    /// いま読んでいる TS の URL（homeserver の直接配信、または EPGStation）
    @State private var tsSource: URL?
    /// 直接配信で再生を始めたが、まだ一度も再生に入っていない（ここで失敗したら EPGStation に切り替える）
    @State private var directPending = false
    /// 「もう一度」で開き直したとき、シークできるようになったらこの位置へ戻す
    @State private var resumeAt: Double?
    /// 字幕の文字の一覧（字幕で探す）
    @State private var showCaptionText = false

    private static let speeds: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    private var file: ESVideoFile? {
        recorded.videoFiles?.first { $0.type == "encoded" } ?? recorded.videoFiles?.first
    }
    private var useAVPlayer: Bool { file?.type == "encoded" }
    private var dataURL: URL? {
        guard !useAVPlayer, let file, let base = Servers.webBML else { return nil }
        return BMLURL.make(base: base, videoFileId: file.id)
    }

    var body: some View {
        // Group だと onAppear / onDisappear が各分岐に付き、たたむたびに最初から再生し直しになる（ZStack にする）
        ZStack {
            if session.minimized {
                miniBar
            } else if useAVPlayer {
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
        .onChange(of: dataMode) { _, v in DebugLog.log("ui", "dataMode=\(v) bml.ready=\(bml.ready) status=\(bml.status) footprint=\(DebugLog.footprintMB()) MB")
            guard v else { return }
            for sec in [4.0, 12.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                    DebugLog.windowShot("window-\(Int(sec))s"); bml.snapshot("web-\(Int(sec))s")
                }
            }
        }
        .onAppear { start() }
        .task { await loadChapters() }
        .onChange(of: engine.position) { _, _ in autoSkipIfNeeded() }
        .onChange(of: engine.state) { _, s in handleStateChange(s) }
        .onChange(of: engine.isSeekable) { _, ok in
            if !useAVPlayer { updateNowPlaying() }
            if ok, let t = resumeAt { resumeAt = nil; engine.seek(to: t) }
        }
        .onReceive(clockTicker) { _ in onClockTick() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // 背面・PiP ではハードウェアのエンコーダーが使えないので、それまでの分で保存する
            if engine.isRecordingClip { toggleClip() }
        }
        .onChange(of: engine.pip.isActive) { _, on in if on && engine.isRecordingClip { toggleClip() } }
        .onChange(of: engine.isPaused) { _, _ in if !useAVPlayer { updateNowPlaying() } }
        .onChange(of: session.seekRequest) { _, r in
            // 再生中の録画を、字幕で探すから別の位置で開き直した
            guard let r, r.recordedId == recorded.id else { return }
            session.seekRequest = nil
            seek(to: r.time)
        }
        .sheet(isPresented: $showCaptionText) {
            if let file, let name = file.filename, let client = Servers.chapters {
                CaptionTextSheet(client: client, videoFileId: file.id, filename: name, recordedId: recorded.id,
                                 position: currentPosition) { t in
                    showCaptionText = false
                    seek(to: t)
                }
            }
        }
        .task(id: "\(commentsOn)-\(jkID ?? "")") {
            if commentsOn {
                comments.loadPast(jkID: jkID, from: recorded.start,
                                  to: recorded.start.addingTimeInterval(recorded.durationSeconds))
            } else {
                comments.stopAll()
            }
        }
        .onDisappear {
            // 続きからの位置へまだ飛んでいない（開いてすぐ閉じた）ときは、前の位置を消さない
            if resumeAt == nil && currentPosition > 0 {
                WatchPositions.save(recorded.id, position: currentPosition, duration: currentDuration)
            }
            comments.stopAll()
            nowPlaying.deactivate()
            engine.stop()
            avPlayer?.pause()
            requestOrientation(.all)
        }
    }

    private func start() {
        radio.stop()
        engine.captionHandler = { packets in
            if captionsOn { captions.feed(packets) }
        }
        guard let file else { return }
        let url = es.videoURL(fileId: file.id)
        // 字幕で探すから開いたらその位置、そうでなければ前回やめた位置（あれば）から
        var saved = WatchPositions.position(recorded.id)
        if let r = session.seekRequest, r.recordedId == recorded.id {
            session.seekRequest = nil
            saved = r.time
            showToast("\(clock(r.time)) から再生")
        } else if let saved { resumedFrom = saved; showToast("続きから再生（\(clock(saved))）") }
        if useAVPlayer {
            let p = AVPlayer(url: url)
            avPlayer = p
            if let saved { p.seek(to: CMTime(seconds: saved, preferredTimescale: 600)) }
            p.play()
        } else {
            if let saved { resumeAt = saved }      // シークできるようになったら飛ぶ（既存の仕組み）
            nowPlaying.activate(onPlay: { engine.setPaused(false); updateNowPlaying() },
                                onPause: { engine.setPaused(true); updateNowPlaying() },
                                onSkip: { engine.seek(by: $0); updateNowPlaying() })
            engine.durationHint = recorded.durationSeconds    // libavformat が長さを出せなかったときの代わり
            // EPGStation の channelId = networkId * 100000 + serviceId。サブチャンネルの録画で、その番組の映像・音声を選ぶ
            engine.preferredServiceId = recorded.channelId.map { $0 % 100_000 }
            // 元の TS は EPGStation（Node）を通さず、homeserver のファイルを直接読む。
            // 使えるかを先に HEAD で確かめると毎回最大 4 秒待つので、使える前提でいきなり開き、
            // 再生に入る前に失敗したときだけ EPGStation に切り替える
            let src: URL
            if let name = file.filename, let c = Servers.chapters {
                directPending = true
                src = c.rawURL(filename: name)
                DebugLog.log("rec", "直接再生 id=\(file.id) \(name)")
            } else {
                directPending = false
                src = url
                DebugLog.log("rec", "EPGStation 経由で再生 id=\(file.id)（直接配信の設定なし）")
            }
            tsSource = src
            engine.play(url: src, file: true)
        }
    }

    private func handleStateChange(_ s: PlayerEngine.State) {
        switch s {
        case .playing:
            directPending = false
        case .failed(let msg):
            guard directPending, let file else { return }
            directPending = false
            let fallback = es.videoURL(fileId: file.id)
            DebugLog.log("rec", "直接再生に失敗、EPGStation に切り替え: \(msg)")
            tsSource = fallback
            engine.play(url: fallback, file: true)
        default:
            break
        }
    }

    // MARK: - CM（チャプター）

    /// いま CM の中なら、そのブロック
    private var currentCM: (start: Double, end: Double)? {
        cmBlocks.first { $0.start - 0.5 <= engine.position && engine.position < $0.end - 1.0 }
    }

    private func skipCM() {
        if let b = currentCM { engine.seek(to: b.end + 0.3) }
    }

    private func autoSkipIfNeeded() {
        if let a = autoSkipped, engine.position < a - 5 { autoSkipped = nil }   // ブロックより前へ戻ったら、また対象にする
        guard cmDetection, autoSkipCM, !engine.isPaused, scrub == nil, let b = currentCM else { return }
        if autoSkipped == b.start { return }
        autoSkipped = b.start
        engine.seek(to: b.end + 0.3)
    }

    /// 解析は homeserver 側で非同期に走る（約 1 分/時間）。終わるまで 3 秒おきに聞く（最大 約 30 分）
    private func loadChapters() async {
        guard cmDetection, !useAVPlayer, let file, let name = file.filename, let client = Servers.chapters else { return }
        for _ in 0..<600 {
            if Task.isCancelled { return }
            do {
                let info = try await client.chapters(videoFileId: file.id, filename: name)
                switch info.status {
                case "ready":
                    cmBlocks = info.blocks
                    cmStatus = info.blocks.isEmpty ? "CM は見つかりませんでした" : "CM \(info.blocks.count) か所を検出"
                    return
                case "error":
                    cmStatus = "CM の検出に失敗しました"
                    return
                default:
                    cmStatus = "CM を解析中… \(Int((info.progress ?? 0) * 100))%"
                }
            } catch {
                cmStatus = "CM 検出サービスに接続できません"
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func cmSkipButton(compact: Bool = false) -> some View {
        let on = currentCM != nil
        return Button { skipCM() } label: {
            HStack(spacing: 6) {
                Image(systemName: "forward.end.fill")
                Text(compact ? "CM" : "CMスキップ")
            }
            .font(Theme.F.jp(13, .bold))
            .foregroundStyle(on ? Theme.C.onAccent : Theme.C.muted)
            .padding(.horizontal, 14).frame(height: compact ? 40 : 36)
            .background(on ? Theme.C.accent : Theme.C.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!on)
    }

    /// シークバーの下に CM の区間を赤い帯で示す
    private var cmStrip: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                let d = max(engine.duration, 1)
                ForEach(Array(cmBlocks.enumerated()), id: \.offset) { _, b in
                    RoundedRectangle(cornerRadius: 1.5).fill(Theme.C.rec.opacity(0.8))
                        .frame(width: max((b.end - b.start) / d * g.size.width, 2), height: 4)
                        .offset(x: b.start / d * g.size.width)
                }
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 14)   // Slider のつまみの余白に合わせる
    }

    // MARK: - 共通部品

    private var videoStack: some View {
        ZStack {
            Theme.C.video
            if !(dataMode && bml.videoRect != nil) {
                VideoSurface(layer: engine.displayLayer)
                    .aspectRatio(engine.info.displayAspect, contentMode: .fit)
            }
            CaptionOverlay(controller: captions)
                .aspectRatio(engine.info.displayAspect, contentMode: .fit)
                .opacity(captionsOn ? 1 : 0)
                .allowsHitTesting(false)
            if commentsOn {
                CommentOverlay(controller: comments)
                    .aspectRatio(engine.info.displayAspect, contentMode: .fit)
                    .allowsHitTesting(false)
            }
            if dataMode, let dataURL {
                BMLWebView(url: dataURL, controller: bml).aspectRatio(16.0 / 9.0, contentMode: .fit)
                if let r = bml.videoRect {
                    GeometryReader { g in
                        VideoSurface(layer: engine.displayLayer).frame(width: r.width * g.size.width, height: r.height * g.size.height)
                            .offset(x: r.minX * g.size.width, y: r.minY * g.size.height)
                    }
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .allowsHitTesting(false)
                }
            }
            stateOverlay
            toastLayer
        }
    }

    // MARK: - 実況・キャプチャ・続きから・ロック画面

    /// 録画した局の実況 ID
    private var jkID: String? {
        guard let cid = recorded.channelId, let ch = epg.channelInfo[cid] else { return nil }
        return JikkyoChannel.id(name: ch.name, serviceId: ch.serviceId, type: ch.channelType)
    }

    /// いまの再生位置（秒、先頭 = 0）
    private var currentPosition: Double {
        if useAVPlayer { return avPlayer?.currentTime().seconds ?? 0 }
        return engine.position
    }

    private var currentDuration: Double {
        if useAVPlayer, let d = avPlayer?.currentItem?.duration.seconds, d.isFinite { return d }
        return engine.duration > 0 ? engine.duration : recorded.durationSeconds
    }

    /// 0.25 秒ごと: 実況を再生位置に合わせて流す・5 秒ごとに位置を保存・ロック画面の表示
    private func onClockTick() {
        let pos = currentPosition
        guard pos.isFinite else { return }
        let paused = useAVPlayer ? (avPlayer?.rate ?? 0) == 0 : engine.isPaused
        if commentsOn && !paused {
            // TS の先頭 ≒ 録画の開始時刻（EPGStation の startAt）。数秒ずれることがある
            comments.tick(broadcastTime: recorded.start.timeIntervalSince1970 + pos)
        }
        if Date().timeIntervalSince(lastSaved) > 5 && pos > 0 {
            lastSaved = Date()
            WatchPositions.save(recorded.id, position: pos, duration: currentDuration)
            if !useAVPlayer { updateNowPlaying() }
        }
    }

    private func updateNowPlaying() {
        let ch = recorded.channelId.flatMap { epg.channelInfo[$0]?.name } ?? "録画"
        nowPlaying.update(title: recorded.name ?? "", channel: ch, artworkURL: nil, isLive: false,
                          position: engine.position, duration: currentDuration,
                          rate: engine.isPaused ? 0 : engine.playbackRate)
    }

    private func restartFromBeginning() {
        resumedFrom = nil
        WatchPositions.save(recorded.id, position: 0, duration: currentDuration)
        if useAVPlayer { avPlayer?.seek(to: .zero) } else { resumeAt = nil; engine.seek(to: 0) }
    }

    /// 位置へ飛ぶ（TS はシークできるようになるまで待つ）
    private func seek(to t: Double) {
        resumedFrom = nil
        if useAVPlayer {
            avPlayer?.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        } else if engine.isSeekable {
            resumeAt = nil
            engine.seek(to: t)
        } else {
            resumeAt = t
        }
    }

    /// 字幕の文字を出せるか（TS で、homeserver の chapterd がある）
    private var captionTextAvailable: Bool {
        !useAVPlayer && recorded.isRecording != true && file?.filename != nil && Servers.chapters != nil
    }

    private func capture() {
        guard let img = engine.captureImage() else { showToast("まだ映像がありません"); return }
        Task { showToast(await CaptureSaver.save(img)) }
    }

    /// 動画で保存（クリップ）: 1 回目で書き始め、もう 1 回で止めて写真アプリへ。最大 5 分
    private func toggleClip() {
        if engine.isRecordingClip {
            guard let rec = engine.takeClip() else { return }
            showToast("動画を書き出しています…")
            Task {
                let msg = await rec.finishAndSave()
                if !msg.isEmpty { showToast(msg) }
            }
        } else if engine.startClip(onLimit: { if engine.isRecordingClip { toggleClip() } }) {
            showToast("録画を始めました（もう一度押すと保存・最大 5 分）")
        } else {
            showToast("まだ映像がありません")
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

    @ViewBuilder private var stateOverlay: some View {
        switch engine.state {
        case .connecting, .buffering:
            ProgressView().tint(.white).controlSize(.large)
        case .failed(let msg):
            VStack(spacing: 10) {
                Text(msg).multilineTextAlignment(.center).font(Theme.F.caption).foregroundStyle(Theme.C.text)
                Button("もう一度") {
                    let pos = engine.position
                    engine.play(url: tsSource ?? es.videoURL(fileId: file?.id ?? 0), file: true)
                    if pos > 5 { resumeAt = pos }
                }
                    .buttonStyle(.borderedProminent).tint(Theme.C.accent)
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

    private func commitScrub() {
        if let s = scrub { engine.seek(to: s); scrub = nil }
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

    private func toggleCaptions() {
        captionsOn.toggle()
        if !captionsOn { captions.clear() }
    }

    // MARK: - ミニプレイヤー（たたんだとき）

    @State private var mp4Paused = false

    private var miniBar: some View {
        let paused = useAVPlayer ? mp4Paused : engine.isPaused
        return MiniPlayerBar(
            title: recorded.name ?? "録画",
            subtitle: useAVPlayer ? "録画 · MP4" : "録画 · \(clock(engine.position)) / \(clock(engine.duration))",
            video: {
                if useAVPlayer {
                    if let avPlayer { PlayerLayerSurface(player: avPlayer) }
                } else {
                    VideoSurface(layer: engine.displayLayer)
                }
            },
            trailing: {
                Button {
                    if useAVPlayer {
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
                    if dataMode {
                        dataPanel
                    } else {
                        VStack(spacing: 8) {
                            seekSlider
                            if !cmBlocks.isEmpty { cmStrip }
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
                            HStack(spacing: 10) {
                                cmSkipButton()
                                Text(cmStatus).font(Theme.F.caption).foregroundStyle(Theme.C.text4).lineLimit(1)
                                Spacer(minLength: 0)
                                if captionTextAvailable {
                                    Button { showCaptionText = true } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: "text.magnifyingglass")
                                            Text("字幕で探す")
                                        }
                                        .font(Theme.F.jp(13, .bold)).foregroundStyle(Theme.C.text)
                                        .padding(.horizontal, 12).frame(height: 36)
                                        .background(Theme.C.surface, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 20).padding(.top, 12)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            ControlTile(icon: "captions.bubble", label: "字幕", enabled: engine.info.hasCaption,
                                        active: captionsOn) { toggleCaptions() }
                            ControlTile(icon: "d.circle", label: "データ", enabled: dataURL != nil, active: dataMode) { dataMode = true }
                            ControlTile(icon: "text.bubble", label: "実況", enabled: jkID != nil, active: commentsOn) { commentsOn.toggle() }
                            ControlTile(icon: "camera", label: "写真") { capture() }
                            ControlTile(icon: engine.isRecordingClip ? "stop.circle.fill" : "record.circle",
                                        label: engine.isRecordingClip ? "保存" : "録画", active: engine.isRecordingClip) { toggleClip() }
                            PiPTile(pip: engine.pip, supported: true)
                            ControlTile(icon: "arrow.up.left.and.arrow.down.right", label: "全画面") { requestOrientation(.landscape) }
                        }
                        .padding(.horizontal, 12)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(recorded.name ?? "").font(Theme.F.programTitle).foregroundStyle(Theme.C.text).lineSpacing(4)
                            Text(engine.isSeekable ? "TS · シーク可 · データ放送あり" : "TS · シーク準備中…")
                                .font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                            if let d = recorded.description, !d.isEmpty {
                                Text(d).font(Theme.F.jp(13)).foregroundStyle(Theme.C.text3)
                            }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 32)
                    }
                }
            }
        }
    }

    private var dataPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(recorded.name ?? "") · データ放送").font(Theme.F.jp(15, .bold))
                        .foregroundStyle(Theme.C.text).lineLimit(1)
                    StatusLine(text: bml.status, color: bml.isError ? Theme.C.rec : Theme.C.live)
                }
                Spacer()
                Button { dataMode = false } label: {
                    Text("データ終了").font(Theme.F.jp(13, .bold)).foregroundStyle(Theme.C.text)
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(Theme.C.surface, in: Capsule())
                        .overlay(Capsule().stroke(Theme.C.borderStrong))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 14)
            AribRemote(controller: bml).padding(.bottom, 32)
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
                        Text(recorded.name ?? "").font(Theme.F.jp(17, .bold)).foregroundStyle(Theme.C.text).lineLimit(1)
                        Spacer()
                        CapsuleTile(label: "字幕", enabled: engine.info.hasCaption, active: captionsOn) { toggleCaptions() }
                        CapsuleTile(label: "実況", enabled: jkID != nil, active: commentsOn) { commentsOn.toggle() }
                        CapsuleTile(label: "写真") { capture() }
                        CapsuleTile(label: engine.isRecordingClip ? "● 保存" : "録画", active: engine.isRecordingClip) { toggleClip() }
                        if captionTextAvailable { CapsuleTile(label: "文字") { showCaptionText = true } }
                        CapsuleTile(label: "d", enabled: dataURL != nil, active: dataMode) { dataMode.toggle() }
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
                        cmSkipButton(compact: true)
                        speedMenu
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.C.overlayBar)
                }
            }
        }
    }

    // MARK: - 変換済み mp4（AVPlayer）

    private var mp4Layout: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Theme.C.video
                // 標準のプレイヤー画面（PiP ボタン付き）。SwiftUI の VideoPlayer には PiP ボタンが出ない
                if let avPlayer { SystemPlayerView(player: avPlayer) }
                if commentsOn {
                    CommentOverlay(controller: comments)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .allowsHitTesting(false)
                }
                toastLayer
                CircleButton(systemName: "chevron.down", size: 36, fill: Color.black.opacity(0.55),
                             foreground: Theme.C.text) { session.minimize() }
                    .padding(12)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(recorded.name ?? "").font(Theme.F.programTitle).foregroundStyle(Theme.C.text).lineSpacing(4)
                    Text("変換済み（MP4）· 標準のコントロールでシーク可 · データ放送なし")
                        .font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                    if let d = recorded.description, !d.isEmpty {
                        Text(d).font(Theme.F.jp(13)).foregroundStyle(Theme.C.text3)
                    }
                }
                .padding(20)
            }
        }
        .background(Theme.C.bg.ignoresSafeArea())
    }
}

/// AVPlayerViewController をそのまま使う（変換済み mp4 の録画用）。PiP・AirPlay・シークは標準のまま
struct SystemPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}
