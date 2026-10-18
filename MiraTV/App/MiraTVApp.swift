import SwiftUI
import AVFoundation
import UIKit

@main
struct MiraTVApp: App {
    @StateObject private var radio = RadioPlayer()
    @StateObject private var epg = EPGStore()
    @StateObject private var reserves = ReserveStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        DebugLog.start()
        // バックグラウンドやサイレントスイッチ ON でも音を出す
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)

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
            TabView {
                ChannelListView()
                    .tabItem { Label("テレビ", systemImage: "tv") }
                GuideView()
                    .tabItem { Label("番組表", systemImage: "square.grid.3x3") }
                RadioView()
                    .tabItem { Label("ラジオ", systemImage: "radio") }
                RecordingsView()
                    .tabItem { Label("録画", systemImage: "record.circle") }
                SettingsView()
                    .tabItem { Label("設定", systemImage: "gearshape") }
            }
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
