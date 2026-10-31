import SwiftUI
import AVFoundation
import Combine

/// 録画の再生に、radiko の聴き逃し（過去 7 日）を重ねて鳴らす。野球中継の実況をラジオ音声に差し替える用。
/// - 録画の再生位置 + 録画の開始時刻 = その瞬間の放送時刻。ラジオもその時刻に合わせる（時刻で合うので数秒以内）
/// - 聴き逃しは 1 回に取れる長さに限りがありうるので、45 分ずつの窓で取り、再生位置が窓の外へ出たら取り直す
/// - 手で合わせたずれは `offset`（秒、プラスでラジオを先へ）。端末に覚えて、次回もそのまま使う
/// テレビ側の音を消すのは呼び出し側（`isActive` を見る）。ラジオ専用の RadioPlayer とは別の AVPlayer
@MainActor
final class RadioOverlay: ObservableObject {
    enum Phase: Equatable { case off, loading, playing, failed(String) }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var station: RadioStation?
    @Published var offset: Double = UserDefaults.standard.double(forKey: "radioOverlayOffset") {
        didSet { UserDefaults.standard.set(offset, forKey: "radioOverlayOffset") }
    }

    var isActive: Bool { phase != .off }

    private static let window: TimeInterval = 45 * 60
    /// 窓の終わりのこの秒数手前まで来たら、次の窓を取り直す
    private static let edgeMargin: TimeInterval = 30
    private static let jst: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo"); f.dateFormat = "yyyyMMddHHmmss"; return f
    }()

    private let player = AVPlayer()
    private var client: RadioWebClient?
    private var chunkStart: Date?
    private var chunkEnd: Date?
    private var lastSeek = Date.distantPast
    private var bag = Set<AnyCancellable>()
    private var itemBag = Set<AnyCancellable>()

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                guard let self, self.isActive else { return }
                if s == .playing { self.phase = .playing }
            }
            .store(in: &bag)
    }

    /// 7 日より前の録画は聴き逃しに無い
    static func isAvailable(recordedStart: Date) -> Bool {
        recordedStart >= Date().addingTimeInterval(-7 * 86400 + 600)
    }

    func start(station: RadioStation, serverURL: String) {
        guard station.source == .radiko, let c = RadioWebClient(serverURL) else {
            phase = .failed("この局は聴き逃しに対応していません"); return
        }
        UserDefaults.standard.set(station.id, forKey: "radioOverlayStation")
        stopPlayback()
        client = c
        self.station = station
        phase = .loading
        DebugLog.log("radio", "ラジオ実況 開始 \(station.name) offset=\(offset)")
    }

    func stop() {
        stopPlayback()
        station = nil
        client = nil
        phase = .off
    }

    private func stopPlayback() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemBag.removeAll()
        chunkStart = nil; chunkEnd = nil
    }

    /// 0.25 秒ごとに呼ぶ。録画の再生位置に、ラジオの位置を合わせる
    func tick(recordedStart: Date, position: Double, paused: Bool, rate: Double) {
        guard isActive, let station, let client else { return }
        if case .failed = phase { return }
        let target = recordedStart.addingTimeInterval(position + offset)

        // 窓の外（または窓がまだ無い）→ 取り直す
        if let s = chunkStart, let e = chunkEnd, target >= s, target < e.addingTimeInterval(-Self.edgeMargin) {
            guard let item = player.currentItem, item.status == .readyToPlay else { return }
            let current = s.timeIntervalSince1970 + player.currentTime().seconds
            let drift = current - target.timeIntervalSince1970
            if abs(drift) > 1.5, Date().timeIntervalSince(lastSeek) > 3 {
                lastSeek = Date()
                player.seek(to: CMTime(seconds: target.timeIntervalSince(s), preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if paused { if player.timeControlStatus != .paused { player.pause() } }
            else if player.timeControlStatus == .paused || player.rate != Float(rate) {
                player.defaultRate = Float(rate)
                player.rate = Float(rate)
            }
        } else {
            loadChunk(around: target, station: station, client: client)
        }
    }

    private func loadChunk(around target: Date, station: RadioStation, client: RadioWebClient) {
        let ft = target.addingTimeInterval(-20)
        // 聴き逃しは「いま」より先は取れない
        let to = min(ft.addingTimeInterval(Self.window), Date().addingTimeInterval(-30))
        guard to > ft.addingTimeInterval(60) else {
            phase = .failed("この時刻はまだ聴き逃しにできません（放送の少し後から取れます）"); return
        }
        chunkStart = ft; chunkEnd = to
        let url = client.timefreeURL(station: station.id, ft: Self.jst.string(from: ft), to: Self.jst.string(from: to))
        DebugLog.log("radio", "ラジオ実況 窓を取得 \(station.id) \(Self.jst.string(from: ft))〜\(Self.jst.string(from: to))")
        itemBag.removeAll()
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 10
        item.audioTimePitchAlgorithm = .timeDomain
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] st in
                guard let self, st == .failed else { return }
                DebugLog.log("radio", "ラジオ実況 失敗 \(item.error.map(describeError) ?? "原因不明")")
                self.phase = .failed("ラジオを取得できませんでした（\(item.error.map(describeError) ?? "原因不明")）")
            }
            .store(in: &itemBag)
        player.replaceCurrentItem(with: item)
        if phase != .playing { phase = .loading }
        player.play()
    }
}

/// 局とずれを選ぶ画面
struct RadioOverlaySheet: View {
    @ObservedObject var overlay: RadioOverlay
    let recordedStart: Date
    @Environment(\.dismiss) private var dismiss
    @AppStorage("radioWebURL") private var serverURL = Defaults.radioWebURL

    @State private var stations: [RadioStation] = []
    @State private var query = ""
    @State private var loadError: String?

    /// 野球中継でよく使う局（名前に含まれる語）。先頭にまとめて出す
    private static let baseball = ["ニッポン放送", "文化放送", "TBSラジオ", "ABCラジオ", "MBSラジオ", "ラジオ関西",
                                   "東海ラジオ", "CBCラジオ", "RKB", "HBC", "STV", "東北放送", "ベイFM", "広島"]

    private var radikoStations: [RadioStation] {
        stations.filter { $0.source == .radiko && !$0.isRadikoNHK }
    }
    private var shown: [RadioStation] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? radikoStations : radikoStations.filter { $0.name.localizedCaseInsensitiveContains(q) }
        guard q.isEmpty else { return base }
        let fav = base.filter { s in Self.baseball.contains { s.name.contains($0) } }
        let rest = base.filter { s in !fav.contains(where: { $0.id == s.id }) }
        return fav + rest
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let s = overlay.station {
                        HStack {
                            Text(s.name).font(Theme.F.jp(15, .bold))
                            Spacer()
                            Text(statusText).font(Theme.F.caption).foregroundStyle(Theme.C.text3)
                        }
                        Button("ラジオ実況をやめる（テレビの音に戻す）", role: .destructive) { overlay.stop(); dismiss() }
                    }
                    offsetRow
                } header: { Text("ずれの調整") } footer: {
                    Text("ラジオが映像より遅れて聞こえるときは「−」、先に聞こえるときは「＋」。数秒以内に収まります。")
                }
                if !RadioOverlay.isAvailable(recordedStart: recordedStart) {
                    Section { Text("この録画は7日より前なので、radiko の聴き逃しにありません。").foregroundStyle(Theme.C.rec) }
                }
                Section("局") {
                    if let loadError { Text(loadError).foregroundStyle(Theme.C.rec) }
                    ForEach(shown) { s in
                        Button {
                            overlay.start(station: s, serverURL: serverURL)
                            dismiss()
                        } label: {
                            HStack {
                                Text(s.name).foregroundStyle(Theme.C.text)
                                Spacer()
                                if overlay.station?.id == s.id { Image(systemName: "checkmark").foregroundStyle(Theme.C.accent) }
                            }
                        }
                        .disabled(!RadioOverlay.isAvailable(recordedStart: recordedStart))
                    }
                }
            }
            .searchable(text: $query, prompt: "局名")
            .navigationTitle("ラジオ実況")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } } }
            .task { await load() }
        }
        .preferredColorScheme(.dark)
    }

    private var statusText: String {
        switch overlay.phase {
        case .off: ""
        case .loading: "取得中…"
        case .playing: "再生中"
        case .failed(let m): m
        }
    }

    private var offsetRow: some View {
        HStack(spacing: 8) {
            ForEach([-5.0, -1.0], id: \.self) { d in nudge(d) }
            Text(String(format: "%+.0f 秒", overlay.offset)).font(Theme.F.mono(14, .semibold)).frame(minWidth: 64)
            ForEach([1.0, 5.0], id: \.self) { d in nudge(d) }
            Spacer(minLength: 0)
            Button("0") { overlay.offset = 0 }.buttonStyle(.bordered)
        }
    }

    private func nudge(_ d: Double) -> some View {
        Button(String(format: "%+.0f", d)) { overlay.offset += d }.buttonStyle(.bordered)
    }

    private func load() async {
        guard let c = RadioWebClient(serverURL) else { loadError = "radio-web の設定を確認してください"; return }
        if let cached = c.cachedStations() { stations = cached.stations }
        do { stations = try await c.stations().stations; loadError = nil }
        catch { if stations.isEmpty { loadError = "局一覧の取得に失敗: \(describeError(error))" } }
    }
}

/// 録画再生の `body` に直接足すと型推論が重すぎて通らないので、ここにまとめる
struct RadioOverlayHooks: ViewModifier {
    @ObservedObject var overlay: RadioOverlay
    let engine: PlayerEngine
    @Binding var showSheet: Bool
    let recordedStart: Date

    func body(content: Content) -> some View {
        content
            .onChange(of: overlay.phase) { _, p in
                // ラジオが鳴っている（鳴らそうとしている）間だけテレビの音を消す。失敗したら戻す
                let muted: Bool = (p == .playing || p == .loading)
                engine.isMuted = muted
            }
            .sheet(isPresented: $showSheet) {
                RadioOverlaySheet(overlay: overlay, recordedStart: recordedStart)
            }
    }
}
