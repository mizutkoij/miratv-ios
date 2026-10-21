import SwiftUI
import AVKit
import Combine

/// Usenet のアーカイブ（VPS1 の nzb-dl）の再生。docs/nzb-stream-playback.md
///
/// - 本体が .ts: 自前の FFmpeg エンジン（録画と同じ。Range で読むのでシーク・字幕・PiP が使える）
/// - 本体が .mp4: AVPlayer（配信サービス由来の録画。字幕・データ放送は無い）。画面と操作は TS と同じ自前のもの（AVFilePlayback）
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

    /// mp4・音声ファイル（AVPlayer）
    @StateObject private var av = AVFilePlayback()
    @State private var captionsOn = false
    @State private var showPanel = true
    @State private var scrub: Double?
    /// シークできるようになったらこの位置へ飛ぶ（続きから・もう一度）
    @State private var resumeAt: Double?
    @State private var resumedFrom: Double?
    @State private var toast: String?
    @State private var nowPlaying = TVNowPlaying()
    @State private var lastSaved = Date.distantPast
    /// 次の回へ自動で進む時刻（見終わったときに数秒待つ。「やめる」で nil）
    @State private var autoNextAt: Date?
    /// この回を「見た」にしたか（何度も書かない）
    @State private var markedWatched = false
    @AppStorage("nzbAutoNext") private var autoNext = true
    private static let autoNextDelay: Double = 8
    private let clockTicker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private static let speeds: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

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
        .onChange(of: engine.state) { _, s in handleStateChange(s) }
        .onChange(of: engine.isSeekable) { _, ok in
            if mode == .ts { updateNowPlaying() }
            if ok, let t = resumeAt { resumeAt = nil; engine.seek(to: t) }
        }
        .onChange(of: engine.isPaused) { _, _ in if mode == .ts { updateNowPlaying() } }
        .onReceive(clockTicker) { _ in onClockTick() }
        .onChange(of: engine.reachedEnd) { _, ended in
            if ended && mode == .ts { handleEnded() }
            if !ended && mode == .ts { autoNextAt = nil }      // 案内の間に戻して見始めたら、次へは進まない
        }
        .onChange(of: av.reachedEnd) { _, ended in
            if ended && mode == .mp4 { handleEnded() }
            if !ended && mode == .mp4 { autoNextAt = nil }
        }
        .onChange(of: av.state) { _, s in handleAVState(s) }
        .onChange(of: av.hasPlayed) { _, played in if played && mode == .mp4 { everPlayed = true } }
        .onChange(of: av.isPaused) { _, _ in if mode == .mp4 { updateNowPlaying() } }
        .onChange(of: autoNext) { _, on in if !on { autoNextAt = nil } }
        // TS の録画は背面・PiP ではハードウェアのエンコーダーが使えないので、それまでの分で保存する
        // （mp4 は元のファイルから切り出すので、背面でもそのまま続けられる）
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if mode == .ts && engine.isRecordingClip { toggleClip() }
        }
        .onChange(of: engine.pip.isActive) { _, on in if on && mode == .ts && engine.isRecordingClip { toggleClip() } }
        .onDisappear {
            // 続きからの位置へまだ飛んでいない（開いてすぐ閉じた）ときは、前の位置を消さない
            if resumeAt == nil && currentPosition > 0 {
                WatchPositions.save(key: entry.watchKey, position: currentPosition, duration: currentDuration)
            }
            startTask?.cancel()
            nowPlaying.deactivate()
            saveClipBeforeClosing()
            engine.stop()
            av.stop()
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
            case let e where Self.avVideoMIME[e] != nil:
                playMP4(item, resume: resume, mime: Self.avVideoMIME[e]!)
            case let e where Self.avAudioMIME[e] != nil:
                // 音声だけのファイル（ラジオの録音: m4a / 生の aac / mp3 …）。画面は映像なしで再生する
                playMP4(item, resume: resume, mime: Self.avAudioMIME[e]!)
            default:
                // ts / m2ts / mkv / avi / webm / flv / wmv / mpg / ogg / opus / 分からないとき。
                // 自前のエンジンは libavformat なので、中身を見て判断できるものは何でも開ける
                playTS(item, resume: resume)
            }
        }
    }

    /// iOS 標準のプレイヤー（AVPlayer）に任せる拡張子と、URL に拡張子が無いので教える中身の種類。
    /// 標準で開けなかったものは、自前のエンジン（libavformat）に切り替える
    private static let avVideoMIME: [String: String] = ["mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime"]
    private static let avAudioMIME: [String: String] = [
        "m4a": "audio/mp4", "aac": "audio/aac", "adts": "audio/aac", "mp3": "audio/mpeg",
        "wav": "audio/wav", "flac": "audio/flac", "caf": "audio/x-caf",
    ]

    /// 標準のプレイヤーで開けなかった item（自前のエンジンに切り替えたもの）
    @State private var avFellBack: Set<String> = []

    /// 本体の拡張子。一度調べたものは覚えておく。調べられなければ nil
    private func mainExt(of item: NzbItemRaw) async -> String? {
        if let e = UsenetCatalog.shared.mainExt(item.id) { return e }
        guard let files = try? await client.files(itemName: item.name),
              let main = NzbDlClient.mainFile(files) else { return nil }
        let ext = main.kind
        if !ext.isEmpty { UsenetCatalog.shared.setMainExt(ext, for: item.id) }
        return ext.isEmpty ? nil : ext
    }

    private func playTS(_ item: NzbItemRaw, resume: Double?) {
        av.stop()
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

    private func playMP4(_ item: NzbItemRaw, resume: Double?, mime: String = "video/mp4") {
        mode = .mp4
        engine.stop()
        resumeAt = nil      // TS から切り替わったとき、TS 用の待ちが残ると閉じるときに位置を保存しなくなる
        nowPlaying.activate(onPlay: { av.setPaused(false); updateNowPlaying() },
                            onPause: { av.setPaused(true); updateNowPlaying() },
                            onSkip: { seek(by: $0); updateNowPlaying() })
        // /api/stream/<id> には拡張子が無いので、AVPlayer に中身の種類を教える
        av.play(url: client.streamURL(id: item.id), mime: mime, resume: resume)
    }

    /// mp4 の状態: 再生に入った・読めなかった（標準で読めない中身は自前のエンジンへ、それでもだめなら再投稿へ）
    private func handleAVState(_ s: AVFilePlayback.State) {
        guard mode == .mp4 else { return }
        switch s {
        case .playing:
            updateNowPlaying()
        case .failed(let msg):
            saveClipBeforeClosing()
            DebugLog.log("nzb", "標準プレイヤーでの再生に失敗 id=\(current?.id ?? "?"): \(msg)")
            let pos = av.position > 5 ? av.position : (resumedFrom ?? 0)
            av.stop()
            // 標準のプレイヤーが対応していない中身（HEVC の一部・AC-3 の音声・変則の mp4 など）は、自前のエンジンで開き直す
            if let cur = current, !avFellBack.contains(cur.id) {
                avFellBack.insert(cur.id)
                showToast("標準のプレイヤーで開けないので、別の方法で再生します")
                everPlayed = false     // 自前のエンジンでも読めなければ、再投稿へ切り替えられるように
                playTS(cur, resume: pos > 0 ? pos : nil)
                return
            }
            if !everPlayed, let next = untriedAlternates.first {
                showToast("読み込めなかったので、再投稿で再生します")
                open(next, resume: pos > 0 ? pos : nil)
            } else {
                mode = .unavailable("再生できませんでした\n\(msg)")
            }
        default:
            break
        }
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
        let pos = currentPosition
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
        av.stop()
        open(next, resume: pos > 5 ? pos : (resumeAt ?? resumedFrom))
    }

    // MARK: - 位置・ロック画面

    private var currentPosition: Double { isAV ? av.position : engine.position }

    private var currentDuration: Double { isAV ? av.duration : engine.duration }

    // MARK: - TS と mp4 で同じ操作（どちらのエンジンかは mode で決まる）

    private var isAV: Bool { mode == .mp4 }
    private var isPaused: Bool { isAV ? av.isPaused : engine.isPaused }
    private var rate: Double { isAV ? av.playbackRate : engine.playbackRate }
    private var isSeekable: Bool { isAV ? av.duration > 0 : engine.isSeekable }
    private var reachedEnd: Bool { isAV ? av.reachedEnd : engine.reachedEnd }
    private var displayAspect: CGFloat { isAV ? av.displayAspect : CGFloat(engine.info.displayAspect) }
    private var hasCaption: Bool { !isAV && engine.info.hasCaption }

    private func seek(to t: Double) {
        cancelClipForSeek()
        if isAV { av.seek(to: t) } else { engine.seek(to: t) }
    }

    private func seek(by d: Double) {
        cancelClipForSeek()
        if isAV { av.seek(by: d) } else { engine.seek(by: d) }
    }

    private func togglePause() {
        if isAV { av.togglePause() } else { engine.togglePause() }
    }

    private func setSpeed(_ s: Double) {
        if isAV { av.setSpeed(s) } else { engine.setSpeed(s) }
    }

    /// 映像（TS は自前のレイヤー、mp4 は AVPlayerLayer、音声だけならその表示）
    @ViewBuilder private var videoSurface: some View {
        if isAV {
            if av.hasVideo {
                AVLayerSurface(layer: av.playerLayer)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(Theme.C.muted)
                    Text("音声のみ").font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                }
            }
        } else {
            VideoSurface(layer: engine.displayLayer)
        }
    }

    private var pipActive: Bool { isAV ? av.pipActive : engine.pip.isActive }

    @ViewBuilder private var pipTile: some View {
        if isAV {
            ControlTile(icon: "pip", label: "PiP", enabled: av.hasVideo && av.pipPossible, active: av.pipActive) { av.togglePiP() }
        } else {
            PiPTile(pip: engine.pip, supported: true)
        }
    }

    @ViewBuilder private var pipCapsule: some View {
        if isAV {
            CapsuleTile(label: "PiP", enabled: av.hasVideo && av.pipPossible, active: av.pipActive) { av.togglePiP() }
        } else {
            PiPCapsule(pip: engine.pip, supported: true)
        }
    }

    // MARK: - 録画（クリップ）

    private var isClipping: Bool { isAV ? av.clipStart != nil : engine.isRecordingClip }
    private var canClip: Bool { isAV ? av.hasVideo : true }

    /// 動画で保存: 1 回目で録り始め、もう 1 回で止めて写真アプリへ。最大 5 分。
    /// TS は映っている 1 枚ずつを書き出す。mp4 はその区間を元のファイルから切り出す
    private func toggleClip() {
        if isAV {
            if av.clipStart != nil {
                showToast("動画を書き出しています…（Usenet から読み直すので少しかかります）", seconds: 10)
                Task {
                    let msg = await av.finishClip()
                    if !msg.isEmpty { showToast(msg) }
                }
            } else if av.startClip() {
                showToast("録画を始めました（もう一度押すと保存・最大 5 分）")
            } else {
                showToast("まだ再生の準備ができていません")
            }
            return
        }
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

    /// 閉じる・次の回へ進む・読めなくなったときに録画の途中なら、それまでの分を保存する（捨てない）。
    /// 画面はもう無いので、結果は表示せず記録だけ残す
    private func saveClipBeforeClosing() {
        if let r = av.takeClipRange(), r.to - r.from >= 1 {
            Task {
                let msg = await AVFilePlayback.saveClip(asset: r.asset, from: r.from, to: r.to)
                DebugLog.log("clip", "閉じる前の録画を保存: \(msg)")
            }
        }
        if engine.isRecordingClip, let rec = engine.takeClip() {
            Task {
                let msg = await rec.finishAndSave()
                DebugLog.log("clip", "閉じる前の録画を保存: \(msg)")
            }
        }
    }

    /// 録画の途中でシークしたら、その録画は取り消す（TS のエンジンも同じ）
    private func cancelClipForSeek() {
        guard isClipping else { return }
        if isAV { av.cancelClip() }
        showToast("シークしたので録画を取り消しました")
    }

    private func clipTile() -> some View {
        ControlTile(icon: isClipping ? "stop.circle.fill" : "record.circle",
                    label: isClipping ? "保存 \(clock(isAV ? av.clipSeconds : engine.clipSeconds))" : "録画",
                    enabled: canClip, active: isClipping) { toggleClip() }
    }

    private func clipCapsule() -> some View {
        CapsuleTile(label: isClipping ? "● 保存" : "録画", enabled: canClip, active: isClipping) { toggleClip() }
    }

    // MARK: - 次の回

    /// 同じシリーズの次の回（UsenetCatalog のシリーズのまとめ）
    private var nextEpisode: UsenetEntry? { UsenetCatalog.shared.nextInSeries(entry) }

    private func markWatched() {
        guard !markedWatched else { return }
        markedWatched = true
        UsenetWatched.mark(entry.id)
    }

    /// 最後まで見た: 「見た」にして、次の回があれば少し待ってから進む
    private func handleEnded() {
        markWatched()
        guard autoNext, autoNextAt == nil, nextEpisode != nil else { return }
        autoNextAt = Date().addingTimeInterval(Self.autoNextDelay)
    }

    private func playNext() {
        autoNextAt = nil
        guard let next = nextEpisode else { return }
        DebugLog.log("nzb", "次の回へ \(entry.id) → \(next.id)")
        // 再生画面は作り直される（onDisappear でこの回の位置を保存する）
        session.playUsenet(next, client: client, keepMinimized: true)
    }

    /// 見終わったときの「次の回」の案内（数秒後に自動で進む）
    @ViewBuilder private var nextOverlay: some View {
        if let at = autoNextAt, let next = nextEpisode {
            VStack(alignment: .leading, spacing: 10) {
                // 残り秒数は時計に合わせて描き直す（ほかの状態が変わらなくても進むように）
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let left = max(Int(ceil(at.timeIntervalSince(ctx.date))), 0)
                    Text("次の回 · \(left) 秒後に再生").font(Theme.F.jp(12, .bold)).foregroundStyle(Theme.C.text3)
                }
                Text(next.title).font(Theme.F.jp(15, .bold)).foregroundStyle(Theme.C.text).lineLimit(2)
                if let d = next.airDate {
                    Text("\(Self.shortAir(d)) \(next.station)").font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                }
                HStack(spacing: 10) {
                    Button("今すぐ再生") { playNext() }
                        .buttonStyle(.borderedProminent).tint(Theme.C.accent)
                    Button("やめる") { autoNextAt = nil }
                        .buttonStyle(.bordered).tint(Theme.C.text)
                }
            }
            .padding(12)
            .frame(maxWidth: 360, alignment: .leading)
            .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
            .padding(8)
            // 縦の小さい映像の枠にも収まるように、入りきらなければ縮める
            .minimumScaleFactor(0.7)
        }
    }

    private static let shortAirFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yy/M/d(E) HH:mm"
        return f
    }()

    private static func shortAir(_ d: Date) -> String { shortAirFormatter.string(from: d) }

    /// 0.25 秒ごと: 5 秒ごとに位置を保存・ロック画面の表示・mp4 の失敗の検出・次の回への自動の切り替え
    private func onClockTick() {
        if let at = autoNextAt, autoNext, Date() >= at { playNext(); return }
        // mp4 の録画は 5 分で止めて保存する（TS は ClipRecorder が自分で止める）
        if isAV, let s = av.clipStart, av.position - s >= AVFilePlayback.maxClipSeconds { toggleClip() }
        let pos = currentPosition
        guard pos.isFinite, pos > 0 else { return }
        // 残り 90 秒を切ったら「見た」（エンディングを飛ばして閉じても見たことにする。続きの位置が消えるのと同じ基準）
        let dur = currentDuration
        if !markedWatched, dur > 120, dur - pos < WatchPositions.finishedRemaining { markWatched() }
        if Date().timeIntervalSince(lastSaved) > 5 {
            lastSaved = Date()
            WatchPositions.save(key: entry.watchKey, position: pos, duration: currentDuration)
            updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        nowPlaying.update(title: entry.title, channel: entry.station.isEmpty ? "アーカイブ" : entry.station,
                          artworkURL: nil, isLive: false,
                          position: currentPosition, duration: currentDuration,
                          rate: isPaused ? 0 : rate)
    }

    private func restartFromBeginning() {
        resumedFrom = nil
        WatchPositions.save(key: entry.watchKey, position: 0, duration: currentDuration)
        resumeAt = nil
        seek(to: 0)
    }

    private func capture() {
        if isAV {
            Task {
                guard let img = await av.captureImage() else { showToast("まだ映像がありません"); return }
                showToast(await CaptureSaver.save(img))
            }
            return
        }
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
            videoSurface
                .aspectRatio(displayAspect, contentMode: .fit)
            CaptionOverlay(controller: captions)
                .aspectRatio(displayAspect, contentMode: .fit)
                .opacity(captionsOn ? 1 : 0)
                .allowsHitTesting(false)
            stateOverlay
            nextOverlay
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
            switch av.state {
            case .loading, .buffering:
                loading(av.position > 0 ? "読み込み中…（初めて見る位置は数秒かかります）" : "Usenet から読み込んでいます…")
            default:
                if av.reachedEnd && autoNextAt == nil { restartButton }
            }
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
                if engine.reachedEnd && autoNextAt == nil { restartButton }
            }
        }
    }

    private var restartButton: some View {
        Button { seek(to: 0); if isAV { av.setPaused(false) } } label: {
            Label("最初から再生", systemImage: "gobackward")
                .font(Theme.F.jp(14, .bold)).foregroundStyle(Theme.C.onAccent)
                .padding(.horizontal, 16).frame(height: 44)
                .background(Theme.C.accent, in: Capsule())
        }
        .buttonStyle(.plain)
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
        let r = rate
        return r == r.rounded() ? "\(Int(r))x" : String(format: "%.2gx", r)
    }

    private var sliderBinding: Binding<Double> {
        Binding(get: { scrub ?? currentPosition }, set: { scrub = $0 })
    }

    /// シークは指を離したときだけ（つまみを動かすたびに Usenet を読みに行かないように）
    private func commitScrub() {
        if let s = scrub { resumedFrom = nil; seek(to: s); scrub = nil }
    }

    private var seekSlider: some View {
        Slider(value: sliderBinding, in: 0...max(currentDuration, 1)) { editing in
            if !editing { commitScrub() }
        }
        .tint(Theme.C.accent)
        .disabled(!isSeekable)
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
        .disabled(!isSeekable && systemName != "pause.fill" && systemName != "play.fill")
    }

    private var speedMenu: some View {
        Menu {
            ForEach(Self.speeds, id: \.self) { s in
                Button(s == s.rounded() ? "\(Int(s))x" : String(format: "%.2fx", s)) { setSpeed(s) }
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
                TagView(text: mode == .mp4 ? (av.hasVideo ? "MP4" : "音声") : "TS")
                ForEach(entry.flags, id: \.self) { TagView(text: $0) }
                if !entry.alternates.isEmpty { TagView(text: "再投稿 \(entry.alternates.count)") }
            }
            Text(statusText).font(Theme.F.caption).foregroundStyle(Theme.C.text4)
            if let next = nextEpisode {
                Button { playNext() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "forward.end.fill").foregroundStyle(Theme.C.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("次の回").font(Theme.F.jp(11, .bold)).foregroundStyle(Theme.C.text3)
                            Text(next.title).font(Theme.F.jp(13, .bold)).foregroundStyle(Theme.C.text).lineLimit(1)
                            if let d = next.airDate {
                                Text(Self.shortAir(d)).font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(Theme.C.row, in: RoundedRectangle(cornerRadius: Theme.R.card))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                Toggle("見終わったら次の回へ進む", isOn: $autoNext)
                    .tint(Theme.C.accent)
                    .font(Theme.F.jp(13)).foregroundStyle(Theme.C.text2)
            }
        }
    }

    private var statusText: String {
        var parts: [String] = []
        if !sizeText.isEmpty { parts.append(sizeText) }
        switch mode {
        case .ts: parts.append(engine.isSeekable ? "シーク可（初めての位置は数秒）" : "シーク準備中…")
        case .mp4: parts.append(isSeekable ? "シーク可 · 字幕なし" : "読み込み中…")
        default: break
        }
        if let c = current, c.id != entry.id { parts.append("再投稿を再生中") }
        return parts.joined(separator: " · ")
    }

    // MARK: - ミニプレイヤー

    private var miniBar: some View {
        let paused = isPaused
        return MiniPlayerBar(
            title: entry.title,
            subtitle: "アーカイブ · \(clock(currentPosition)) / \(clock(currentDuration))",
            video: { videoSurface },
            trailing: {
                Button { togglePause() } label: {
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
                            Text(clock(scrub ?? currentPosition)).font(Theme.F.mono(12, .medium))
                            Spacer()
                            Text(clock(currentDuration)).font(Theme.F.mono(12, .medium))
                        }
                        .foregroundStyle(Theme.C.text3)
                        HStack(spacing: 18) {
                            transportButton("gobackward.15") { seek(by: -15) }
                            transportButton(isPaused ? "play.fill" : "pause.fill", size: 54, filled: true) {
                                togglePause()
                            }
                            transportButton("goforward.30") { seek(by: 30) }
                            Spacer()
                            speedMenu
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 12)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ControlTile(icon: "captions.bubble", label: "字幕", enabled: hasCaption,
                                    active: captionsOn) { toggleCaptions() }
                        ControlTile(icon: "camera", label: "写真", enabled: canClip) { capture() }
                        clipTile()
                        pipTile
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
                        CapsuleTile(label: "字幕", enabled: hasCaption, active: captionsOn) { toggleCaptions() }
                        CapsuleTile(label: "写真", enabled: canClip) { capture() }
                        clipCapsule()
                        pipCapsule
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.C.overlayBar)

                    Spacer()

                    HStack(spacing: 10) {
                        transportButton("gobackward.15", size: 40) { seek(by: -15) }
                        transportButton(isPaused ? "play.fill" : "pause.fill", size: 44, filled: true) {
                            togglePause()
                        }
                        transportButton("goforward.30", size: 40) { seek(by: 30) }
                        Text(clock(scrub ?? currentPosition)).font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text2)
                        seekSlider
                        Text(clock(currentDuration)).font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text2)
                        speedMenu
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.C.overlayBar)
                }
            }
        }
    }
}
