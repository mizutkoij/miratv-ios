import SwiftUI
import AVFoundation
import UIKit

@main
struct MiraTVApp: App {
    @StateObject private var radio = RadioPlayer()
    @StateObject private var epg = EPGStore()
    @StateObject private var reserves = ReserveStore()
    @StateObject private var session = PlaybackSession()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        DebugLog.start()
        DispatchQueue.global(qos: .utility).async { DiskCache.prune() }
        // バックグラウンドやサイレントスイッチ ON でも音を出す
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // 5.1ch を 5.1ch のまま受け取れる出力（AirPlay の対応機器など）に、まとめずに渡す
        try? AVAudioSession.sharedInstance().setSupportsMultichannelContent(true)

        // DESIGN.md「TabBar」: 地は bg、上に divider の線、選択中は accent・他は text4
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Theme.C.bg)
        appearance.shadowColor = UIColor(Theme.C.divider)
        for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            item.normal.iconColor = UIColor(Theme.C.text4)
            item.normal.titleTextAttributes = [.foregroundColor: UIColor(Theme.C.text4)]
            item.selected.iconColor = UIColor(Theme.C.accent)
            item.selected.titleTextAttributes = [.foregroundColor: UIColor(Theme.C.accent)]
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .bottom) {
            TabView {
                ChannelListView().miniPlayerInset()
                    .tabItem { Label("テレビ", systemImage: "tv") }
                GuideView().miniPlayerInset()
                    .tabItem { Label("番組表", systemImage: "square.grid.3x3") }
                RadioView().miniPlayerInset()
                    .tabItem { Label("ラジオ", systemImage: "radio") }
                RecordingsView().miniPlayerInset()
                    .tabItem { Label("録画", systemImage: "record.circle") }
                SettingsView().miniPlayerInset()
                    .tabItem { Label("設定", systemImage: "gearshape") }
            }
                // 再生画面。閉じるまで作り直さないので、たたんでも再生が続く
                if let item = session.item {
                    PlayerHost(item: item).id(item.id)
                }
            }
            .onChange(of: radio.mode) { _, m in
                if m != .idle { session.close() }      // ラジオを鳴らしたらテレビは閉じる
            }
            .environmentObject(session)
            .environmentObject(radio)
            .environmentObject(epg)
            .environmentObject(reserves)
            .tint(Theme.C.accent)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { _, p in
                DebugLog.phase(p == .active ? "active" : p == .background ? "background" : "inactive")
            }
        }
    }
}
