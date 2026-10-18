import SwiftUI
import UIKit

/// いま再生しているもの（ライブ・録画）。アプリ全体で 1 つ。
///
/// 再生画面はタブの上に重ねて置き、閉じるまで View を作り直さない（= エンジンも止めない）。
/// 「たたむ」と下のミニプレイヤーになり、再生したまま番組表・録画一覧・設定などを触れる。
/// ×で閉じたときだけ再生画面が消え、onDisappear でエンジンが止まる。
@MainActor
final class PlaybackSession: ObservableObject {

    enum Item: Identifiable {
        case live(service: MirakurunService, services: [MirakurunService], client: MirakurunClient)
        case recorded(ESRecorded, EPGStationClient)

        var id: String {
            switch self {
            case .live(let s, _, _): "live-\(s.id)"
            case .recorded(let r, _): "rec-\(r.id)"
            }
        }
    }

    @Published private(set) var item: Item?
    @Published private(set) var minimized = false
    /// ライブで「いま見ている局」。再生画面の中で選局しても item（= 画面の id）は変えずに、ここだけ更新する
    private(set) var liveServiceID: Int?

    func playLive(_ service: MirakurunService, services: [MirakurunService], client: MirakurunClient) {
        // いま見ている局なら、作り直さずに広げるだけ
        if case .live = item, liveServiceID == service.id { expand(); return }
        item = .live(service: service, services: services, client: client)
        liveServiceID = service.id
        minimized = false
    }

    /// 再生画面の中で選局したとき（画面は作り直さない）
    func updateLive(_ service: MirakurunService) {
        if case .live = item { liveServiceID = service.id }
    }

    func playRecorded(_ recorded: ESRecorded, es: EPGStationClient) {
        if case .recorded(let r, _) = item, r.id == recorded.id { expand(); return }
        item = .recorded(recorded, es)
        minimized = false
    }

    func minimize() {
        guard item != nil else { return }
        // 横向きの全画面からたたんだら、一覧が見やすいよう縦に戻す
        Self.requestOrientation(.portrait)
        withAnimation(.easeOut(duration: 0.25)) { minimized = true }
    }

    func expand() {
        Self.requestOrientation(.all)
        withAnimation(.easeOut(duration: 0.25)) { minimized = false }
    }

    func close() {
        Self.requestOrientation(.all)
        withAnimation(.easeOut(duration: 0.2)) {
            item = nil
            minimized = false
        }
        liveServiceID = nil
    }

    static func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

/// タブの上に重ねる再生画面。全画面のときはタブごと覆い、たたむとタブバーのすぐ上のミニプレイヤーになる
struct PlayerHost: View {
    let item: PlaybackSession.Item
    @EnvironmentObject private var session: PlaybackSession

    /// iPhone のタブバーの高さ（ミニプレイヤーをその上に置く）
    private static let tabBarHeight: CGFloat = 49

    var body: some View {
        Group {
            switch item {
            case .live(let service, let services, let client):
                PlayerView(service: service, services: services, client: client)
            case .recorded(let recorded, let es):
                RecordedPlayerView(recorded: recorded, es: es)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: session.minimized ? nil : .infinity, alignment: .bottom)
        .background {
            if !session.minimized { Theme.C.bg.ignoresSafeArea() }
        }
        .padding(.bottom, session.minimized ? Self.tabBarHeight + 6 : 0)
        .ignoresSafeArea(.keyboard)          // 検索欄などでキーボードが出ても、ミニプレイヤーは持ち上げない
        .transition(.move(edge: .bottom))
    }
}

/// ミニプレイヤーの共通の見た目（左に小さな映像、真ん中に題名、右にボタン）
struct MiniPlayerBar<Video: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let video: () -> Video
    @ViewBuilder let trailing: () -> Trailing
    let onExpand: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            video()
                .frame(width: 107, height: 60)
                .background(Theme.C.video)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.F.jp(14, .bold)).foregroundStyle(Theme.C.text).lineLimit(1)
                Text(subtitle).font(Theme.F.caption).foregroundStyle(Theme.C.text3).lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.C.text2).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("再生を終了")
        }
        .padding(8)
        .background(Theme.C.raised, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0x2A3038)))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture(perform: onExpand)
        .gesture(DragGesture(minimumDistance: 20).onEnded { v in
            if v.translation.height < -30 { onExpand() }        // 上へはじくと広げる
        })
        .padding(.horizontal, 8)
        .accessibilityAction(named: "全画面で見る", onExpand)
    }
}

/// ミニプレイヤーが出ている間、各タブの一番下が隠れないように空ける（タブバーは動かさない）
private struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject private var session: PlaybackSession
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if session.item != nil && session.minimized { Color.clear.frame(height: 82) }
        }
    }
}

extension View {
    func miniPlayerInset() -> some View { modifier(MiniPlayerInset()) }
}
