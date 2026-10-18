import SwiftUI

/// MiraTV のデザイントークン（DESIGN.md と同じ値）
enum Theme {
    enum C {
        static let bg = Color(hex: 0x0D1014)
        static let surface = Color(hex: 0x161A20)
        static let row = Color(hex: 0x13171C)
        static let raised = Color(hex: 0x1D222A)
        static let rowActive = Color(hex: 0x1A1F27)
        static let rowActiveBorder = Color(hex: 0x3A3220)
        static let divider = Color(hex: 0x1E232B)
        static let border = Color(hex: 0x262C35)
        static let borderStrong = Color(hex: 0x343B45)

        static let text = Color(hex: 0xECEEF1)
        static let text2 = Color(hex: 0xB4BCC6)
        static let text3 = Color(hex: 0x9AA3AE)
        static let text4 = Color(hex: 0x8C95A1)
        static let muted = Color(hex: 0x6B7480)
        static let placeholder = Color(hex: 0x4A525D)

        static let accent = Color(hex: 0xF5A524)
        static let onAccent = Color(hex: 0x1A1205)
        static let accentTint = Color(hex: 0x1F1C15)

        static let live = Color(hex: 0x3DD68C)
        static let rec = Color(hex: 0xFF5A4E)
        static let onRec = Color(hex: 0x1F0705)
        static let recText = Color(hex: 0xFF8A80)
        static let recTint = Color(hex: 0x2A1615)
        static let recTintBorder = Color(hex: 0x5A2A26)
        static let warn = Color(hex: 0xF5C04A)
        static let warnTint = Color(hex: 0x2A2213)
        static let warnTintBorder = Color(hex: 0x5C4718)
        static let warnText = Color(hex: 0xE5D6B5)

        static let video = Color(hex: 0x05070A)
        static let logoTile = Color(hex: 0xE9ECEF)
        static let logoTileText = Color(hex: 0x5A6370)
        static let scrim = Color.black.opacity(0.55)
        static let overlayBar = Color(hex: 0x05070A).opacity(0.62)
        static let captionBg = Color.black.opacity(0.72)

        /// ARIB リモコンの色ボタン（青・赤・緑・黄の順）
        static let aribBlue = Color(hex: 0x2F6BFF)
        static let aribRed = Color(hex: 0xE0392F)
        static let aribGreen = Color(hex: 0x178A4B)
        static let aribYellow = Color(hex: 0xE8C21A)
        static let onAribYellow = Color(hex: 0x14243B)
    }

    enum F {
        /// Zen Kaku Gothic New を Bundle に入れていればそれ、無ければシステムフォント
        static func jp(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            let name: String
            switch weight {
            case .bold, .heavy, .black, .semibold: name = "ZenKakuGothicNew-Bold"
            case .medium: name = "ZenKakuGothicNew-Medium"
            default: name = "ZenKakuGothicNew-Regular"
            }
            return UIFont(name: name, size: size) != nil ? .custom(name, size: size) : .system(size: size, weight: weight)
        }

        /// IBM Plex Mono（チャンネル番号・時刻）
        static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
            let name = weight == .medium || weight == .regular ? "IBMPlexMono-Medium" : "IBMPlexMono-SemiBold"
            return UIFont(name: name, size: size) != nil
                ? .custom(name, size: size)
                : .system(size: size, weight: weight, design: .monospaced)
        }

        static let screenTitle = jp(28, .bold)
        static let programTitle = jp(21, .bold)
        static let sheetTitle = jp(20, .bold)
        static let section = jp(15, .bold)
        static let rowTitle = jp(15, .bold)
        static let meta = jp(13, .medium)
        static let caption = jp(12)
        static let badge = jp(11, .bold)
    }

    enum R {
        static let card: CGFloat = 14
        static let button: CGFloat = 12
        static let segmentOuter: CGFloat = 12
        static let segmentInner: CGFloat = 9
        static let sheet: CGFloat = 22
        static let progress: CGFloat = 2
    }

    enum Logo {
        static let list = CGSize(width: 64, height: 36)
        static let radio = CGSize(width: 64, height: 32)
        static let card = CGSize(width: 48, height: 27)
        static let inline = CGSize(width: 40, height: 22)
        static let guide = CGSize(width: 36, height: 20)
    }

    /// 番組表: 1 分あたりの高さ
    static let guidePointsPerMinute: CGFloat = 2
    static let guideColumnWidth: CGFloat = 116
    static let guideTimeColumnWidth: CGFloat = 40
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
