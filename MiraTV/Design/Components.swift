import SwiftUI

// DESIGN.md「2. 共通部品」の実装

enum Defaults {
    static let mirakurunURL = "http://192.0.2.10:36192"
    /// もう 1 台の Mirakurun（ABEMA の仮想チューナー + 地上波 97・BS 460・CS 375 局）。チャンネル画面で切り替える
    static let mirakurun2URL = "http://192.0.2.10:36196"
    static let radioWebURL = "http://192.0.2.20:8090"
    /// VPS2 の radio-search（server/radio-search。radiko.db の約 50 万件の過去番組を全文検索）
    static let radioSearchURL = "http://192.0.2.20:8091"
    static let epgstationURL = "http://192.0.2.10:8888"
    /// 2 台目の Mirakurun に付いている EPGStation（韓国・配信系。番組表だけ使う）
    static let epgstation2URL = "http://192.0.2.10:8890"
    /// homeserver の VOD Monitor（jod-vod-monitor。J-Sports / GIANTS TV / FOD などの HLS 配信の一覧）
    static let vodMonitorURL = "http://192.0.2.10:36197"
    /// homeserver の tvh-dvrd（韓国のサーバーの TVHeadend が録画したものを中継する。server/tvh-dvrd.mjs）
    static let tvhDvrURL = "http://192.0.2.10:36205"
    /// homeserver の m2-programs（2 台目の番組情報を局で絞って返す。server/m2-programs.mjs）。ブリッジの /api/programs は絞り込みを守らず 14MB 返す
    static let programsLiteURL = "http://192.0.2.10:36206"
    /// homeserver の CM 検出サービス（録画の無音位置から CM ブロックを推定）
    static let chapterURL = "http://192.0.2.10:23235"
    /// データ放送（web-bml）は自分で立てたサーバーの URL を設定画面で入れる。空なら「データ」は使えない
    /// homeserver の Docker コンテナ `web-bml`（Tailscale のアドレスだけで待ち受け、CPU 0.5 コア・メモリ 512MB に制限）
    static let webbmlURL = "http://192.0.2.10:23234"
    /// 自前の中継（server/streamd.py）。映像を抜いた音声だけの TS などを、エンコードせずに返す
    static let streamdURL = "http://192.0.2.10:23236"
    /// VPS1 の nzb-dl（Usenet のアーカイブ、:8083、Tailscale のみ）。アドレスと API キーは設定画面で入れる（リポジトリには置かない）
    static let nzbdlURL = ""
}

extension Date {
    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "HH:mm"
        return f
    }()
    /// "18:00"（JST）
    var hm: String { Self.hmFormatter.string(from: self) }
}

/// ロゴ枠: 放送ロゴは白地・透過が多いので明るい枠に載せる
struct LogoTile: View {
    let url: URL?
    let size: CGSize

    private var radius: CGFloat { size.height >= 30 ? 6 : (size.height >= 24 ? 4 : 3) }

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Theme.C.logoTile)
            .frame(width: size.width, height: size.height)
            .overlay {
                CachedImage(url: url).padding(2)
            }
    }
}

/// 進行バー（高さ 3、横画面は 4）
struct ProgressBar: View {
    let progress: Double
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.C.border)
                Capsule().fill(Theme.C.accent)
                    .frame(width: g.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: height)
    }
}

/// 地上波 / BS / CS のような切り替え
struct SegmentedPills<T: Hashable>: View {
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(label(option))
                        .font(Theme.F.jp(14, .bold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(selection == option ? Theme.C.onAccent : Theme.C.text2)
                        .background(selection == option ? Theme.C.accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: Theme.R.segmentInner))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.C.surface, in: RoundedRectangle(cornerRadius: Theme.R.segmentOuter))
    }
}

/// 地域・日付のチップ
struct ChipView: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.F.jp(13, selected ? .bold : .medium))
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .foregroundStyle(selected ? Theme.C.onAccent : Theme.C.text2)
                .background(selected ? Theme.C.accent : Theme.C.surface, in: Capsule())
                .overlay(Capsule().stroke(selected ? Color.clear : Theme.C.border))
        }
        .buttonStyle(.plain)
    }
}

/// 7pt の丸 + 状態テキスト
struct StatusLine: View {
    let text: String
    var color: Color = Theme.C.live

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(Theme.F.meta).foregroundStyle(Theme.C.text3)
        }
    }
}

/// 配信元などの小さなタグ
struct TagView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.F.jp(10, .bold))
            .foregroundStyle(Theme.C.text3)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.C.borderStrong))
    }
}

/// 画面タイトル + 右側の操作
struct ScreenHeader<Trailing: View>: View {
    let title: String
    let status: StatusLine?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.F.screenTitle).foregroundStyle(Theme.C.text)
                if let status { status }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

/// 44pt の丸ボタン
struct CircleButton: View {
    let systemName: String
    var size: CGFloat = 44
    var fill: Color = Theme.C.surface
    var foreground: Color = Theme.C.text2
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(fill, in: Circle())
                .overlay(Circle().stroke(Theme.C.border))
        }
        .buttonStyle(.plain)
    }
}

/// 行カードの背景
struct RowCard: ViewModifier {
    var active = false
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(active ? Theme.C.rowActive : Theme.C.row, in: RoundedRectangle(cornerRadius: Theme.R.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.card)
                .stroke(active ? Theme.C.rowActiveBorder : Theme.C.border.opacity(0.0)))
    }
}

extension View {
    func rowCard(active: Bool = false) -> some View { modifier(RowCard(active: active)) }
}

/// 画面の向きを要求する（再生画面の「全画面」「縦に戻す」）。.all で制限を解く
func requestOrientation(_ mask: UIInterfaceOrientationMask) {
    guard let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene else { return }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
}
