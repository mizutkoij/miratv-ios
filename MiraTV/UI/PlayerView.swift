import SwiftUI
import AVFoundation
import UIKit

/// 再生画面。DESIGN.md「再生（縦）」「再生（横・全画面）」「データ放送＋リモコン」「再生モード」の実装。
/// 向きは端末の回転で縦/横レイアウトが自動で切り替わり、「全画面」ボタンは横向きを要求する。
struct PlayerView: View {
    let services: [MirakurunService]
    let client: MirakurunClient

    @State private var current: MirakurunService
    @StateObject private var engine = PlayerEngine()
    @StateObject private var hls = HLSPlayback()
    @StateObject private var bml = BMLController()
    @StateObject private var captions = CaptionController()
    @StateObject private var network = NetworkKind()
    @EnvironmentObject private var epg: EPGStore
    @EnvironmentObject private var radio: RadioPlayer
    @EnvironmentObject private var session: PlaybackSession
    @StateObject private var comments = CommentController()
    @AppStorage("showComments") private var commentsOn = false
    @State private var nowPlaying = TVNowPlaying()
    @State private var toast: String?
    /// ロック画面の「停止」で止めたライブ（もう一度押すと選局し直す）
    @State private var livePaused = false

    // MARK: 追っかけ再生（streamd が直近の放送をディスクに貯めている）
    @AppStorage("timeshiftEnabled") private var timeshiftEnabled = true
    @State private var tsInfo: TimeshiftInfo?
    @State private var tsInfoAt = Date()
    /// いま追っかけ再生中か（false = 普通のライブ）
    @State private var tsActive = false
    /// 追っかけで流し始めた位置（バッファ開始からの秒）。いまの位置 = これ + engine.position
    @State private var tsBase: Double = 0
    @State private var tsPausedAt: Date?
    @State private var tsScrub: Double?
    @State private var tsRetried = false
    @AppStorage("autoLowDataOnCellular") private var autoLowData = false
    /// 変換配信（EPGStation の ffmpeg）を使うか。既定はオフ＝サーバーに変換の負荷をかけない
    @AppStorage("allowServerTranscode") private var allowTranscode = false

    @State private var now = Date()
    @State private var showPanel = true
    @State private var summaryExpanded = false
    @State private var dataMode = false
    @State private var captionsOn = false
    @State private var showQuality = false
    /// -1 = 原画質（Mirakurun を端末でデコード）、-2 = 音声のみ（同じストリームで映像をデコードしない）、
    /// 0〜999 = EPGStation の HLS mode、1000 以上 = EPGStation の変換 M2TS（端末のエンジンで再生）
    @State private var modeID = -1
    @State private var hlsNames: [String] = []
    @State private var m2tsNames: [String] = []
    @State private var m2tsModes: [Int] = []
    /// 音声のみを streamd 経由で再生中か / この画面で streamd が使えなかったか
    @State private var usingRelay = false
    /// ワンセグ（モード -3 か、ワンセグの音声）で再生中 / この画面でワンセグが開けなかった
    @State private var usingOneSeg = false
    @State private var oneSegFailed = false
    @State private var relayFailed = false
    @State private var loadingModes = false
    private let ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    init(service: MirakurunService, services: [MirakurunService], client: MirakurunClient) {
        self.services = services
        self.client = client
        _current = State(initialValue: service)
    }

    private var program: Program? { epg.current(current, at: now) }
    private var isHLS: Bool { modeID >= 0 && modeID < PlaybackChoice.m2tsBase }
    private var isM2TS: Bool { modeID >= PlaybackChoice.m2tsBase }
    private var isAudioOnly: Bool { modeID == -2 }
    private var isOneSegMode: Bool { modeID == -3 }
    /// 全サービス（ワンセグを含む。一覧の `services` はテレビの局だけ）
    @State private var allServices: [MirakurunService] = []
    /// いまの局のワンセグ（同じ networkId = 同じ放送局の部分受信サービス）
    private var oneSegService: MirakurunService? {
        guard current.channel?.type == "GR" else { return nil }
        // 同じ放送局でも別の物理チャンネル（中継局の重なり）だと 2 本目のチューナーが要るので、チャンネルも一致させる
        return allServices.filter {
            $0.isOneSeg && $0.networkId == current.networkId && $0.channel?.channel == current.channel?.channel
        }.min { $0.serviceId < $1.serviceId }
    }
    private var isDualMono: Bool { !isHLS && (program?.isDualMono ?? false) }
    /// 主/副の切替は 2ch の音声なら選べるようにする（番組表の「二か国語」情報が取れていなくても使えるように）
    private var audioSelectable: Bool { !isHLS && (isDualMono || engine.info.audioChannels == 2) }
    private var webBMLURL: URL? { Servers.webBML.flatMap { BMLURL.make(base: $0, service: current) } }
    private var dataAvailable: Bool { modeID == -1 && webBMLURL != nil }
    private var choices: [PlaybackChoice] {
        let relay = Servers.streamd != nil && !relayFailed
        var base: [PlaybackChoice] = [.original]
        if oneSegService != nil { base.append(.oneSeg) }
        base.append(!relay && oneSegService != nil ? .audioOnlyOneSeg : .audioOnly(relay: relay))
        guard allowTranscode else { return base }
        return base + PlaybackChoice.fromHLS(hlsNames) + PlaybackChoice.fromM2TS(m2tsNames)
    }
    private var captionAvailable: Bool { !isHLS && engine.info.hasCaption }

    private func toggleCaptions() {
        captionsOn.toggle()
        if !captionsOn { captions.clear() }
    }

    /// 字幕は映像と同じ範囲に透明な WebView を重ねて描く（操作は通さない）
    /// この局の実況 ID（ニコニコ実況）。分からない局は nil
    private var jkID: String? { JikkyoChannel.id(name: current.name, serviceId: current.serviceId, type: current.channel?.type) }

    @ViewBuilder private var commentLayer: some View {
        if commentsOn && !isAudioOnly {
            CommentOverlay(controller: comments)
                .aspectRatio(isHLS ? 16.0 / 9.0 : engine.info.displayAspect, contentMode: .fit)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var toastLayer: some View {
        if let toast {
            Text(toast).font(Theme.F.jp(13, .bold)).foregroundStyle(Theme.C.text)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.black.opacity(0.75), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 12)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    private func showToast(_ s: String) {
        withAnimation { toast = s }
        let shown = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if toast == shown { withAnimation { toast = nil } } }
    }

    private func capture() {
        guard let img = engine.captureImage() else { showToast("まだ映像がありません"); return }
        Task { showToast(await CaptureSaver.save(img)) }
    }

    /// ロック画面の再生 / 停止。ライブは一時停止できないので、止める → もう一度押すと選局し直す
    private func toggleLivePlayback() {
        if livePaused {
            livePaused = false
            startPlayback()
        } else {
            livePaused = true
            engine.stop()
            hls.stop()
            comments.clear?()
        }
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        nowPlaying.update(title: program?.title ?? "", channel: current.name, artworkURL: client.logoURL(for: current),
                          isLive: !tsActive, rate: (livePaused || (tsActive && engine.isPaused)) ? 0 : 1,
                          programStart: program?.start, programEnd: program?.end,
                          behind: tsActive ? max(liveEdge - tsPosition, 0) : nil)
    }

    @ViewBuilder private var captionLayer: some View {
        if !isHLS {
            CaptionOverlay(controller: captions)
                .aspectRatio(engine.info.displayAspect, contentMode: .fit)
                .opacity(captionsOn ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    var body: some View {
        // Group だと onAppear / onDisappear が中の各分岐に付き、たたむたびに再生が止まって最初からになる。
        // ZStack は 1 つの入れ物なので、再生画面が消えるとき（× で閉じたとき）だけ呼ばれる
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
        .persistentSystemOverlays(session.minimized ? .automatic : .hidden)
        .onChange(of: dataMode) { _, v in DebugLog.log("ui", "dataMode=\(v) bml.ready=\(bml.ready) status=\(bml.status) footprint=\(DebugLog.footprintMB()) MB")
            guard v else { return }
            for sec in [4.0, 12.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                    DebugLog.windowShot("window-\(Int(sec))s"); bml.snapshot("web-\(Int(sec))s")
                }
            }
        }
        .onAppear {
            radio.stop()   // テレビとラジオは同時に鳴らさない
            allServices = client.cachedServices() ?? services
            nowPlaying.activate(
                onPlay: {
                    if tsActive { if engine.isPaused { tsTogglePause() } } else if livePaused { toggleLivePlayback() }
                },
                onPause: {
                    // 追っかけが使えるなら、止めた位置から後で続きを見られるように一時停止する
                    if tsAvailable && tsInfo != nil { if !(tsActive && engine.isPaused) { tsTogglePause() } }
                    else if !livePaused { toggleLivePlayback() }
                },
                onSkip: nil)
            updateNowPlaying()
            engine.captionHandler = { packets in
                if captionsOn { captions.feed(packets) }
            }
            startPlayback()
        }
        .task(id: "\(current.id)-\(tsAvailable)") {
            // 見ている間は 5 秒おきに start を呼ぶ（貯め続ける合図。止めると 3 分で streamd が止まる）
            tsInfo = nil                       // 前の局のバッファの範囲を出さない
            guard tsAvailable else { return }
            let svc = current
            while !Task.isCancelled {
                if let info = await TimeshiftClient.start(svc), !Task.isCancelled {
                    tsInfo = info.stopped == true ? nil : info
                    tsInfoAt = Date()
                } else if Date().timeIntervalSince(tsInfoAt) > 15 {
                    tsInfo = nil               // streamd に届かない間は、追っかけの操作を出さない
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            TimeshiftClient.stop(svc)          // 局を替えた・閉じた・追っかけを使わなくなった
        }
        .task(id: "\(current.id)-\(commentsOn)-\(livePaused)") {
            if commentsOn && !livePaused { comments.startLive(jkID: jkID) } else { comments.stopAll() }
        }
        .onChange(of: tsInfo?.id) { old, new in
            // バッファが作り直された（長く止めていた・チューナーを録画に譲った等）→ 前の位置はもう無いのでライブへ
            guard tsActive, let old, let new, new != old else { return }
            showToast("追っかけ用の録画が途切れたので、ライブに戻しました")
            goLive()
        }
        .onChange(of: program?.id) { _, _ in updateNowPlaying() }
        .onChange(of: current.id) { _, _ in livePaused = false; updateNowPlaying() }
        .onDisappear {
            comments.stopAll()
            nowPlaying.deactivate()
            engine.stop()
            hls.stop()
            setOrientation(.all)
        }
        .onReceive(ticker) { now = $0 }
        .onChange(of: engine.state) { _, s in handleEngineState(s) }
        .task(id: current.id) {
            await epg.loadDetail(service: current, es: Servers.epgstation, mirakurun: client)
        }
        .task {
            // 変換配信を使わない設定なら、EPGStation の設定を読みにも行かない（省データの自動切替もしない）
            guard allowTranscode, let es = Servers.epgstation else { return }
            // 変換のプリセットはサーバーの設定ファイルで決まっていて、まず変わらない。前回の分をすぐ使い、裏で取り直す
            let savedKey = "hlsModeNames"
            if let saved = UserDefaults.standard.stringArray(forKey: savedKey) { hlsNames = saved } else { loadingModes = true }
            if let saved = UserDefaults.standard.stringArray(forKey: "m2tsModeNames"),
               let idx = UserDefaults.standard.array(forKey: "m2tsModeIndexes") as? [Int], idx.count == saved.count {
                m2tsNames = saved; m2tsModes = idx
            }
            if let modes = try? await es.liveHLSModes() {
                hlsNames = modes.names
                m2tsNames = modes.m2tsNames
                m2tsModes = modes.m2tsModes
                UserDefaults.standard.set(modes.names, forKey: savedKey)
                UserDefaults.standard.set(modes.m2tsNames, forKey: "m2tsModeNames")
                UserDefaults.standard.set(modes.m2tsModes, forKey: "m2tsModeIndexes")
            }
            loadingModes = false
            // モバイル回線で自動省データが有効なら、最も軽い HLS に切り替える
            if autoLowData, network.isExpensive, !hlsNames.isEmpty, modeID == -1 {
                modeID = hlsNames.count - 1
                startPlayback()
            }
        }
        .sheet(isPresented: $showQuality) {
            QualitySheet(choices: choices, selectedID: modeID, isExpensiveNetwork: network.isExpensive,
                         loadingChoices: loadingModes, transcodeAllowed: allowTranscode) { c in setMode(c.id) }
        }
    }

    // MARK: - 再生の制御

    private func startPlayback() {
        engine.audioMode = .both
        tsActive = false
        tsPausedAt = nil
        engine.tracksStreamPosition = false
        usingRelay = false
        usingOneSeg = false
        let es = Servers.epgstation
        if isHLS, let es {
            engine.stop()
            dataMode = false
            hls.play(url: es.liveHLSURL(channelId: current.id, mode: modeID))
        } else if isM2TS, let es, m2tsModes.indices.contains(modeID - PlaybackChoice.m2tsBase) {
            // 変換した TS は端末のエンジンで再生する（字幕・主/副・PiP はそのまま使える。データ放送は消える）
            hls.stop()
            dataMode = false
            engine.audioOnly = false
            engine.play(url: es.liveM2TSURL(channelId: current.id, mode: m2tsModes[modeID - PlaybackChoice.m2tsBase]))
        } else if isOneSegMode, !oneSegFailed, let one = oneSegService {
            // ワンセグ: 同じ電波の低解像度の放送。サーバーは何も変換しない
            hls.stop()
            dataMode = false
            engine.audioOnly = false
            DebugLog.log("player", "ワンセグで再生 \(one.name) sid=\(one.serviceId)")
            usingOneSeg = true
            engine.play(url: client.streamURL(for: one))
        } else {
            if modeID != -2 { modeID = -1 }     // ワンセグの無い局（BS など）に切り替えたら原画質へ
            hls.stop()
            if isAudioOnly { dataMode = false }
            engine.audioOnly = isAudioOnly
            // 音声のみ: 1. 自前の中継（映像を抜いた本放送の音声） 2. ワンセグの音声（地上波） 3. 原画質を受けて端末で映像を捨てる
            if isAudioOnly, !relayFailed, let relay = Servers.streamdAudioURL(current) {
                usingRelay = true
                engine.play(url: relay)
            } else if isAudioOnly, !oneSegFailed, let one = oneSegService {
                usingOneSeg = true
                engine.play(url: client.streamURL(for: one))
            } else {
                engine.play(url: client.streamURL(for: current))
            }
        }
    }

    /// 中継で開けなかった（streamd が止まっている等）→ 以後この画面では Mirakurun から直接
    private func handleEngineState(_ s: PlayerEngine.State) {
        if case .playing = s { tsRetried = false }
        guard case .failed(let msg) = s else { return }
        if tsActive {
            // 追っかけ中に切れた（長い一時停止でサーバーが接続を閉じた等）→ 1 回だけ、その位置で開き直す。駄目ならライブへ
            DebugLog.log("player", "追っかけ再生が切れました: \(msg)")
            if !tsRetried, tsInfo != nil { tsRetried = true; openTimeshift(at: tsPosition) } else {
                showToast("追っかけ再生を続けられないので、ライブに戻しました")
                goLive()
            }
            return
        }
        if usingOneSeg {
            // ワンセグが開けなかった → この画面では本放送から（音声のみなら端末で映像を捨てる）
            DebugLog.log("player", "ワンセグで開けず、本放送で再生: \(msg)")
            oneSegFailed = true
            usingOneSeg = false
            if isOneSegMode { modeID = -1 }
            engine.audioOnly = isAudioOnly
            engine.play(url: client.streamURL(for: current))
            return
        }
        guard usingRelay else { return }
        DebugLog.log("player", "streamd で開けず、Mirakurun から音声のみで再生: \(msg)")
        relayFailed = true
        usingRelay = false
        engine.audioOnly = true
        if !oneSegFailed, let one = oneSegService {
            usingOneSeg = true
            engine.play(url: client.streamURL(for: one))
        } else {
            engine.play(url: client.streamURL(for: current))
        }
    }

    private func setMode(_ id: Int) {
        guard id != modeID else { return }
        modeID = id
        startPlayback()
    }

    private func select(_ s: MirakurunService) {
        guard s.id != current.id else { return }
        current = s
        session.updateLive(s)      // 一覧で「いま見ている局」を押したら、作り直さずに広げるだけにする
        captions.clear()
        startPlayback()
    }

    private func step(_ delta: Int) {
        guard let i = services.firstIndex(where: { $0.id == current.id }), !services.isEmpty else { return }
        select(services[(i + delta + services.count) % services.count])
    }

    private func setOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }

    private func cycleAudio() {
        switch engine.audioMode {
        case .both: engine.audioMode = .main
        case .main: engine.audioMode = .sub
        case .sub: engine.audioMode = .both
        }
    }

    private var audioLabel: String {
        guard audioSelectable else { return !isHLS && engine.info.audioChannels == 6 ? "5.1ch" : "音声" }
        switch engine.audioMode {
        case .both: return "主+副"
        case .main: return "主"
        case .sub: return "副"
        }
    }

    private var qualityLabel: String {
        if isHLS, hlsNames.indices.contains(modeID), let c = choices.first(where: { $0.id == modeID }) {
            return "\(c.title) · \(hlsNames[modeID])"
        }
        if isM2TS, m2tsNames.indices.contains(modeID - PlaybackChoice.m2tsBase) {
            return "変換 · \(m2tsNames[modeID - PlaybackChoice.m2tsBase])"
        }
        if isAudioOnly { return "音声のみ" }
        if isOneSegMode { return "ワンセグ" }
        switch engine.info.audioChannels {
        case 0: return "原画質"
        case 6: return "原画質 · 5.1ch"
        default: return "原画質 · \(engine.info.audioChannels)ch"
        }
    }

    // MARK: - 映像

    @ViewBuilder private var videoSurface: some View {
        if isAudioOnly {
            audioOnlyPlaceholder
        } else if isHLS {
            PlayerLayerSurface(player: hls.player).aspectRatio(16.0 / 9.0, contentMode: .fit)
        } else {
            VideoSurface(layer: engine.displayLayer).aspectRatio(engine.info.displayAspect, contentMode: .fit)
        }
    }

    /// 音声のみのときの映像の代わり（局ロゴと番組名）
    private var audioOnlyPlaceholder: some View {
        VStack(spacing: 10) {
            LogoTile(url: client.logoURL(for: current), size: Theme.Logo.list)
            Text("音声のみ").font(Theme.F.jp(13, .bold)).foregroundStyle(Theme.C.text2)
            Text(program?.title ?? "").font(Theme.F.caption).foregroundStyle(Theme.C.text4).lineLimit(1)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .background(Theme.C.video)
    }

    private var boxed: Bool { dataMode && bml.videoRect != nil }

    @ViewBuilder private var rawSurface: some View {
        if isHLS { PlayerLayerSurface(player: hls.player) } else { VideoSurface(layer: engine.displayLayer) }
    }

    /// データ放送画面の「映像の枠」に、実際の映像を縮小して出す（BML は枠の位置を空けているだけで、映像は描かない）
    @ViewBuilder private var boxedVideo: some View {
        if dataMode, let r = bml.videoRect {
            GeometryReader { g in
                rawSurface.frame(width: r.width * g.size.width, height: r.height * g.size.height)
                    .offset(x: r.minX * g.size.width, y: r.minY * g.size.height)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.2), value: r)
        }
    }

    /// データ放送（web-bml）を映像の上に透明で重ねる
    @ViewBuilder private var bmlOverlay: some View {
        if dataMode, let url = webBMLURL {
            BMLWebView(url: url, controller: bml)
                .id(current.id)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
        }
    }

    // MARK: - 追っかけ再生

    /// 追っかけを使えるか（設定がオン・streamd がある・原画質で見ている）
    private var tsAvailable: Bool { timeshiftEnabled && modeID == -1 && Servers.streamd != nil }

    /// ライブの端（バッファ開始からの秒）。info は 5 秒おきなので、その間は経過時間で進める
    private var liveEdge: Double {
        guard let info = tsInfo else { return 0 }
        return info.seconds + (info.stopped == true ? 0 : Date().timeIntervalSince(tsInfoAt))
    }

    private var tsPosition: Double { tsActive ? tsBase + engine.position : liveEdge }

    private func clampTS(_ t: Double) -> Double {
        min(max(t, tsInfo?.availableFrom ?? 0), max(liveEdge - 3, 0))
    }

    @discardableResult
    private func openTimeshift(at t: Double, paused: Bool = false) -> Bool {
        let target = clampTS(t)
        guard let info = tsInfo, let url = Servers.timeshiftURL(current, "play", from: target, bufferID: info.id) else { return false }
        livePaused = false
        DebugLog.log("player", "追っかけ再生 \(Int(target))s（ライブの \(Int(liveEdge - target))s 前）")
        tsActive = true
        tsBase = target
        tsPausedAt = paused ? Date() : nil
        hls.stop()
        dataMode = false
        engine.audioOnly = false
        engine.tracksStreamPosition = true
        engine.play(url: url)
        if paused { engine.setPaused(true) }
        updateNowPlaying()
        return true
    }

    private func goLive() {
        startPlayback()          // 追っかけをやめて、Mirakurun から直接のライブに戻す
        updateNowPlaying()
    }

    /// 一時停止 / 再開。ライブ中に押したら、その場で止めて追っかけに入る
    private func tsTogglePause() {
        guard tsActive else { openTimeshift(at: liveEdge - 2, paused: true); return }
        if engine.isPaused {
            // 20 秒以上止めていたら、サーバーが接続を閉じているので、その位置で開き直す
            if let at = tsPausedAt, Date().timeIntervalSince(at) > 20 { openTimeshift(at: tsPosition) } else { engine.setPaused(false) }
            tsPausedAt = nil
        } else {
            engine.setPaused(true)
            tsPausedAt = Date()
        }
        updateNowPlaying()
    }

    private func tsSkip(_ d: Double) {
        let target = tsPosition + d
        if target >= liveEdge - 3 { if tsActive { goLive() }; return }
        openTimeshift(at: target)
    }

    private func tsClock(_ s: Double) -> String {
        let t = Int(max(s, 0))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// 映像の下（横画面では下のバーの上）に出す: ⏪15・一時停止・シークバー（貯まっている範囲）・LIVE
    @ViewBuilder private var timeshiftBar: some View {
        if tsAvailable, let info = tsInfo, info.seconds > 5 {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let edge = liveEdge
                let lower = info.availableFrom
                let pos = min(tsPosition, edge)
                let behind = edge - pos
                HStack(spacing: 8) {
                    Button { tsSkip(-15) } label: {
                        Image(systemName: "gobackward.15").font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.C.text).frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain).accessibilityLabel("15 秒戻る")
                    Button { tsTogglePause() } label: {
                        Image(systemName: tsActive && engine.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.C.text).frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain).accessibilityLabel(tsActive && engine.isPaused ? "再生" : "一時停止")
                    Slider(value: Binding(get: { tsScrub ?? pos }, set: { tsScrub = $0 }),
                           in: lower...max(edge, lower + 1)) { editing in
                        guard !editing, let v = tsScrub else { return }
                        tsScrub = nil
                        if v >= edge - 3 { if tsActive { goLive() } } else { openTimeshift(at: v) }
                    }
                    .tint(tsActive ? Theme.C.accent : Theme.C.live)
                    Button { if tsActive { goLive() } } label: {
                        Text(tsActive ? "-\(tsClock(behind))" : "LIVE")
                            .font(Theme.F.mono(11, .semibold))
                            .foregroundStyle(tsActive ? Theme.C.text : Theme.C.onAccent)
                            .padding(.horizontal, 8).frame(height: 26)
                            .background(tsActive ? Theme.C.surface : Theme.C.live, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tsActive ? "ライブに戻る" : "ライブ")
                }
                .padding(.horizontal, 12)
            }
        }
    }

    // MARK: - ミニプレイヤー（たたんだとき）

    private var isMutedNow: Bool { isHLS ? hls.isMuted : engine.isMuted }

    private var miniBar: some View {
        MiniPlayerBar(
            title: program?.title ?? current.name,
            subtitle: "\(current.name) · \(qualityLabel)",
            video: {
                if isAudioOnly {
                    LogoTile(url: client.logoURL(for: current), size: Theme.Logo.card)
                } else if isHLS {
                    PlayerLayerSurface(player: hls.player)
                } else {
                    VideoSurface(layer: engine.displayLayer)
                }
            },
            trailing: {
                Button {
                    if isHLS { hls.isMuted.toggle() } else { engine.isMuted.toggle() }
                } label: {
                    Image(systemName: isMutedNow ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.C.text).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isMutedNow ? "消音を解除" : "消音")
            },
            onExpand: { session.expand() },
            onClose: { session.close() })
    }

    // MARK: - 縦

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Theme.C.video
                if !boxed { videoSurface }
                captionLayer
                commentLayer
                bmlOverlay
                boxedVideo
                statusOverlay
                pausedOverlay
                toastLayer
                CircleButton(systemName: "chevron.down", size: 36, fill: Color.black.opacity(0.55),
                             foreground: Theme.C.text) { session.minimize() }
                    .padding(12)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)

            if dataMode {
                ScrollView { dataPanel }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        timeshiftBar.padding(.top, 6)
                        controlRow
                        if commentsOn, !comments.status.isEmpty {
                            Text(comments.status).font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                                .padding(.horizontal, 16).padding(.bottom, 8)
                        }
                        Divider().overlay(Theme.C.divider)
                        programInfo
                        otherChannels
                        upNext
                    }
                }
            }
        }
    }

    private var controlRow: some View {
        HStack(spacing: 8) {
            ControlTile(icon: "captions.bubble", label: "字幕", enabled: captionAvailable, active: captionsOn) { toggleCaptions() }
            ControlTile(icon: "speaker.wave.2", label: audioLabel, enabled: audioSelectable,
                        active: audioSelectable && engine.audioMode != .both) { cycleAudio() }
            ControlTile(icon: "d.circle", label: "データ", enabled: dataAvailable, active: dataMode) { dataMode.toggle() }
            ControlTile(icon: "text.bubble", label: "実況", enabled: jkID != nil, active: commentsOn) { commentsOn.toggle() }
            ControlTile(icon: "camera", label: "写真", enabled: !isHLS && !isAudioOnly) { capture() }
            PiPTile(pip: engine.pip, supported: !isHLS && !isAudioOnly)
            ControlTile(icon: "arrow.up.left.and.arrow.down.right", label: "全画面") { setOrientation(.landscape) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var programInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LogoTile(url: client.logoURL(for: current), size: Theme.Logo.inline)
                Text(current.remoteControlKeyId.map(String.init) ?? "")
                    .font(Theme.F.mono(15)).foregroundStyle(Theme.C.accent)
                Text(current.name).font(Theme.F.jp(15, .bold)).foregroundStyle(Theme.C.text).lineLimit(1)
                if let p = program {
                    Text("·").foregroundStyle(Theme.C.text4)
                    Text(p.timeRange).font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text4)
                }
                Spacer(minLength: 4)
                Button { showQuality = true } label: {
                    HStack(spacing: 4) {
                        Text(qualityLabel).font(Theme.F.jp(12, .medium))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Theme.C.text2)
                    .padding(.horizontal, 10).frame(height: 28)
                    .overlay(Capsule().stroke(Theme.C.borderStrong))
                }
                .buttonStyle(.plain)
            }
            Text(program?.title ?? "番組情報を取得中…")
                .font(Theme.F.programTitle).foregroundStyle(Theme.C.text)
                .lineSpacing(4)
            ProgressBar(progress: program?.progress(at: now) ?? 0)
            if let text = program?.detailText, !text.isEmpty {
                Text(text)
                    .font(Theme.F.jp(13)).foregroundStyle(Theme.C.text3)
                    .lineLimit(summaryExpanded ? nil : 3)
                    .onTapGesture { withAnimation { summaryExpanded.toggle() } }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var otherChannels: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ほかのチャンネル").font(Theme.F.section).foregroundStyle(Theme.C.text)
                Spacer()
                Text("左右スワイプで選局").font(Theme.F.caption).foregroundStyle(Theme.C.text4)
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(services.filter { $0.id != current.id }) { s in
                        channelCard(s)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 16)
    }

    private func channelCard(_ s: MirakurunService) -> some View {
        Button { select(s) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: Theme.R.card).fill(Theme.C.row)
                        .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.C.border))
                    LogoTile(url: client.logoURL(for: s), size: Theme.Logo.card).padding(10)
                    Text(s.remoteControlKeyId.map(String.init) ?? "")
                        .font(Theme.F.mono(20)).foregroundStyle(Theme.C.text)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(10)
                }
                .frame(width: 148, height: 83)
                Text(s.name).font(Theme.F.caption).foregroundStyle(Theme.C.text3).lineLimit(1)
                Text(epg.current(s, at: now)?.title ?? " ")
                    .font(Theme.F.jp(13, .bold)).foregroundStyle(Theme.C.text).lineLimit(1)
            }
            .frame(width: 148, alignment: .leading)
        }
        .buttonStyle(.plain)
        .task(id: epg.overviewFailed) {
            if epg.overviewFailed { await epg.loadViaMirakurun(s, client: client) }
        }
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Theme.C.divider)
            Text("このあと").font(Theme.F.section).foregroundStyle(Theme.C.text)
                .padding(.horizontal, 20).padding(.top, 6)
            let items = epg.upcoming(current, at: now, limit: 5)
            if items.isEmpty {
                Text("番組情報がありません").font(Theme.F.caption).foregroundStyle(Theme.C.muted)
                    .padding(.horizontal, 20)
            }
            ForEach(items) { p in
                HStack(alignment: .top, spacing: 10) {
                    Text(p.start.hm).font(Theme.F.mono(13)).foregroundStyle(Theme.C.text4)
                        .frame(width: 44, alignment: .leading)
                    Text(p.title).font(Theme.F.jp(14)).foregroundStyle(Theme.C.text).lineLimit(2)
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 32)
    }

    // MARK: - データ放送 + リモコン（縦の下半分）

    private var dataPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(current.remoteControlKeyId.map(String.init) ?? "") \(current.name) · データ放送")
                        .font(Theme.F.jp(15, .bold)).foregroundStyle(Theme.C.text).lineLimit(1)
                    HStack(spacing: 10) {
                        StatusLine(text: bml.status, color: bml.isError ? Theme.C.rec : Theme.C.live)
                        Text("最後の入力: \(bml.lastKey)").font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                    }
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
            .padding(.horizontal, 20)
            .padding(.top, 14)
            AribRemote(controller: bml)
                .padding(.bottom, 32)
        }
    }

    // MARK: - 横（全画面）

    private var landscapeLayout: some View {
        ZStack {
            if !boxed { videoSurface.ignoresSafeArea() }
            captionLayer
            commentLayer
            bmlOverlay
            boxedVideo
            statusOverlay
            pausedOverlay
            toastLayer
            Color.clear.contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showPanel.toggle() } }
            if showPanel {
                VStack(spacing: 0) {
                    landscapeTopBar
                    Spacer()
                    timeshiftBar.padding(.vertical, 4).background(Theme.C.overlayBar)
                    landscapeBottomBar
                }
                HStack {
                    Spacer()
                    channelStepper
                }
                .padding(.trailing, 12)
            }
        }
    }

    private var landscapeTopBar: some View {
        HStack(spacing: 12) {
            CircleButton(systemName: "arrow.down.right.and.arrow.up.left", fill: Color.black.opacity(0.4),
                         foreground: Theme.C.text) { setOrientation(.portrait) }
            LogoTile(url: client.logoURL(for: current), size: Theme.Logo.list)
            VStack(alignment: .leading, spacing: 2) {
                Text(current.name).font(Theme.F.meta).foregroundStyle(Theme.C.text3).lineLimit(1)
                Text(program?.title ?? "").font(Theme.F.jp(17, .bold)).foregroundStyle(Theme.C.text).lineLimit(1)
            }
            Spacer()
            CapsuleTile(label: "字幕", enabled: captionAvailable, active: captionsOn) { toggleCaptions() }
            CapsuleTile(label: audioLabel, enabled: audioSelectable,
                        active: audioSelectable && engine.audioMode != .both) { cycleAudio() }
            CapsuleTile(label: "d", enabled: dataAvailable, active: dataMode) { dataMode.toggle() }
            CapsuleTile(label: "実況", enabled: jkID != nil, active: commentsOn) { commentsOn.toggle() }
            CapsuleTile(label: "写真", enabled: !isHLS && !isAudioOnly) { capture() }
            PiPCapsule(pip: engine.pip, supported: !isHLS && !isAudioOnly)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.C.overlayBar)
    }

    private var channelStepper: some View {
        VStack(spacing: 8) {
            stepButton(systemName: "chevron.up", delta: -1)
            stepButton(systemName: "chevron.down", delta: 1)
        }
    }

    private func stepButton(systemName: String, delta: Int) -> some View {
        let target: MirakurunService? = {
            guard let i = services.firstIndex(where: { $0.id == current.id }), !services.isEmpty else { return nil }
            return services[(i + delta + services.count) % services.count]
        }()
        return Button { step(delta) } label: {
            VStack(spacing: 2) {
                if delta < 0 { Image(systemName: systemName) }
                Text(target?.remoteControlKeyId.map(String.init) ?? "").font(Theme.F.mono(13))
                if delta > 0 { Image(systemName: systemName) }
            }
            .foregroundStyle(Theme.C.text)
            .frame(width: 44, height: 56)
            .background(Theme.C.overlayBar, in: RoundedRectangle(cornerRadius: Theme.R.card))
        }
        .buttonStyle(.plain)
    }

    private var landscapeBottomBar: some View {
        HStack(spacing: 12) {
            Text(program?.start.hm ?? "--:--").font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text2)
            ProgressBar(progress: program?.progress(at: now) ?? 0, height: 4)
            Text(program?.end.hm ?? "--:--").font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text2)
            Text("LIVE").font(Theme.F.jp(11, .bold)).foregroundStyle(Theme.C.onAccent)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.C.live, in: Capsule())
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.C.overlayBar)
    }

    // MARK: - 状態表示

    @ViewBuilder private var pausedOverlay: some View {
        if livePaused {
            Button { toggleLivePlayback() } label: {
                Label("停止中 · タップで再生", systemImage: "play.fill")
                    .font(Theme.F.jp(14, .bold)).foregroundStyle(Theme.C.onAccent)
                    .padding(.horizontal, 16).frame(height: 44)
                    .background(Theme.C.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var statusOverlay: some View {
        if isHLS {
            switch hls.state {
            case .loading:
                VStack(spacing: 8) {
                    ProgressView().tint(.white).controlSize(.large)
                    Text("変換配信を準備中…（数秒かかります）").font(Theme.F.caption).foregroundStyle(Theme.C.text3)
                }
            case .failed(let msg): failureView(msg)
            default: EmptyView()
            }
        } else {
            switch engine.state {
            case .connecting, .buffering: ProgressView().tint(.white).controlSize(.large)
            case .failed(let msg): failureView(msg)
            default: EmptyView()
            }
        }
    }

    private func failureView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text(msg).multilineTextAlignment(.center).font(Theme.F.caption)
            Button("再接続") { startPlayback() }
                .buttonStyle(.borderedProminent).tint(Theme.C.accent)
        }
        .foregroundStyle(Theme.C.text).padding()
    }
}

// MARK: - 操作ボタン

/// 再生（縦）の操作行の 1 マス（高さ 52、角丸 12、アイコン 20 + ラベル 11）
struct ControlTile: View {
    let icon: String
    let label: String
    var enabled = true
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 20, weight: .medium))
                Text(label).font(Theme.F.jp(11, .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(active ? Theme.C.onAccent : (enabled ? Theme.C.text2 : Theme.C.muted))
            .background(active ? Theme.C.accent : Theme.C.surface, in: RoundedRectangle(cornerRadius: Theme.R.button))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.button).stroke(active ? Color.clear : Theme.C.border))
            .opacity(enabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// 横画面の上バーのカプセルボタン（高さ 40）
struct CapsuleTile: View {
    let label: String
    var enabled = true
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(Theme.F.jp(13, .medium))
                .padding(.horizontal, 14).frame(height: 40)
                .foregroundStyle(active ? Theme.C.onAccent : (enabled ? Theme.C.text : Theme.C.muted))
                .background(active ? Theme.C.accent : Theme.C.surface.opacity(0.8), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// PiP の状態（可否・動作中）を観測して ControlTile に反映する
struct PiPTile: View {
    @ObservedObject var pip: PiPController
    let supported: Bool

    var body: some View {
        ControlTile(icon: "pip", label: "PiP", enabled: supported && pip.isPossible, active: pip.isActive) { pip.toggle() }
    }
}

struct PiPCapsule: View {
    @ObservedObject var pip: PiPController
    let supported: Bool

    var body: some View {
        CapsuleTile(label: "PiP", enabled: supported && pip.isPossible, active: pip.isActive) { pip.toggle() }
    }
}

/// エンジンが持つ AVSampleBufferDisplayLayer を貼るだけの UIView
struct VideoSurface: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        v.backgroundColor = .black
        v.attach(layer)
        return v
    }

    /// ここでは付け直さない（全画面 ⇄ ミニの切替中は 2 つの View が同時にあり、取り合いになるため）。
    /// 付けるのは作ったとき（makeUIView）だけ。新しく出た方がレイヤーを持つ
    func updateUIView(_ uiView: HostView, context: Context) {}

    static func dismantleUIView(_ v: HostView, coordinator: ()) {
        // まだ自分が持っている場合だけ外す（すでに新しい方に移っていたら触らない）
        if v.videoLayer?.superlayer === v.layer { v.videoLayer?.removeFromSuperlayer() }
        v.releaseLayer()
    }

    final class HostView: UIView {
        private(set) var videoLayer: CALayer?

        /// 映像のレイヤーをこの View に付ける。1 つのレイヤーは 1 か所にしか付けられないので、
        /// ほかの View に付いていればそこから外れてこちらに移る
        func attach(_ l: CALayer) {
            videoLayer = l
            layer.addSublayer(l)
            setNeedsLayout()
        }

        func releaseLayer() { videoLayer = nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            // たたむアニメーション中は古い View もしばらく残る。レイヤーがもう別の View に移っていたら大きさを変えない
            guard let videoLayer, videoLayer.superlayer === layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
