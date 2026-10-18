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
    @Environment(\.dismiss) private var dismiss
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
    @ViewBuilder private var captionLayer: some View {
        if !isHLS {
            CaptionOverlay(controller: captions)
                .aspectRatio(engine.info.displayAspect, contentMode: .fit)
                .opacity(captionsOn ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                (landscape ? Theme.C.video : Theme.C.bg).ignoresSafeArea()
                if landscape { landscapeLayout } else { portraitLayout }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
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
            engine.captionHandler = { packets in
                if captionsOn { captions.feed(packets) }
            }
            startPlayback()
        }
        .onDisappear {
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
        guard case .failed(let msg) = s else { return }
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

    // MARK: - 縦

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Theme.C.video
                if !boxed { videoSurface }
                captionLayer
                bmlOverlay
                boxedVideo
                statusOverlay
                CircleButton(systemName: "chevron.down", size: 36, fill: Color.black.opacity(0.55),
                             foreground: Theme.C.text) { dismiss() }
                    .padding(12)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)

            if dataMode {
                ScrollView { dataPanel }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        controlRow
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
            bmlOverlay
            boxedVideo
            statusOverlay
            Color.clear.contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showPanel.toggle() } }
            if showPanel {
                VStack(spacing: 0) {
                    landscapeTopBar
                    Spacer()
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
        v.videoLayer = layer
        return v
    }

    func updateUIView(_ uiView: HostView, context: Context) {}

    final class HostView: UIView {
        var videoLayer: CALayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let videoLayer { layer.addSublayer(videoLayer) }
            }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}
