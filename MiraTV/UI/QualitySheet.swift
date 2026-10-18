import SwiftUI

/// 再生モードの選択肢。id = -1 が原画質（Mirakurun の MPEG-2 TS を端末でデコード）、
/// 0 以上は EPGStation のライブ HLS の mode（`/api/config` の streamConfig.live.hls の並び順）
struct PlaybackChoice: Identifiable, Hashable {
    let id: Int
    let title: String
    let source: String
    let spec: String
    let abilities: String
    var isOriginal: Bool { id == -1 }

    static let original = PlaybackChoice(
        id: -1, title: "原画質", source: "Mirakurun",
        spec: "MPEG-2 TS · 1440×1080i · 約15Mbps", abilities: "データ放送◯ 5.1ch◯ 主/副音声◯")

    /// EPGStation の HLS 名（"720p" など）から選択肢を作る。先頭を高画質、以降を省データとして並べる
    static func fromHLS(_ names: [String]) -> [PlaybackChoice] {
        names.enumerated().map { i, name in
            PlaybackChoice(
                id: i,
                title: i == 0 ? "高画質変換" : "省データ",
                source: "EPGStation",
                spec: "H.264 · \(name) · HLS",
                abilities: "データ放送× 主/副音声×")
        }
    }
}

/// DESIGN.md「再生モード（Quality）」のボトムシート
struct QualitySheet: View {
    let choices: [PlaybackChoice]
    let selectedID: Int
    let isExpensiveNetwork: Bool
    let loadingChoices: Bool
    let onSelect: (PlaybackChoice) -> Void

    @AppStorage("autoLowDataOnCellular") private var autoLow = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule().fill(Theme.C.borderStrong).frame(width: 40, height: 5).frame(maxWidth: .infinity)
            HStack {
                Text("再生モード").font(Theme.F.sheetTitle).foregroundStyle(Theme.C.text)
                Spacer()
                StatusLine(text: isExpensiveNetwork ? "モバイル回線" : "Wi-Fi",
                           color: isExpensiveNetwork ? Theme.C.warn : Theme.C.live)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(choices) { c in card(c) }
                    if loadingChoices {
                        Text("EPGStation の設定を確認中…").font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                    }
                    audioOnlyCard
                }
                toggles.padding(.top, 8)
            }
        }
        .padding(20)
        .background(Theme.C.surface.ignoresSafeArea())
        .presentationDetents([.large, .fraction(0.75)])
        .presentationCornerRadius(Theme.R.sheet)
    }

    private func card(_ c: PlaybackChoice) -> some View {
        let on = c.id == selectedID
        return Button {
            onSelect(c)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(c.title).font(Theme.F.jp(16, .bold)).foregroundStyle(Theme.C.text)
                    Spacer()
                    Text(c.source).font(Theme.F.caption).foregroundStyle(Theme.C.text3)
                }
                Text(c.spec).font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.text3)
                Text(c.abilities).font(Theme.F.caption).foregroundStyle(Theme.C.text4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(on ? Theme.C.accentTint : Theme.C.row, in: RoundedRectangle(cornerRadius: Theme.R.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.card)
                .stroke(on ? Theme.C.accent : Theme.C.border, lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    /// 音声のみは EPGStation 側に専用の設定が無い（streamConfig に無い）ため、今は選べない
    private var audioOnlyCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("音声のみ").font(Theme.F.jp(16, .bold)).foregroundStyle(Theme.C.muted)
                Spacer()
                Text("EPGStation").font(Theme.F.caption).foregroundStyle(Theme.C.muted)
            }
            Text("AAC 2ch 128kbps · 画面オフ・バックグラウンド").font(Theme.F.mono(12, .medium)).foregroundStyle(Theme.C.muted)
            Text("EPGStation に音声のみの配信設定がないため、今は選べません").font(Theme.F.caption).foregroundStyle(Theme.C.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.C.row, in: RoundedRectangle(cornerRadius: Theme.R.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.C.border))
        .opacity(0.7)
    }

    private var toggles: some View {
        VStack(spacing: 0) {
            Toggle("モバイル回線では自動で省データ", isOn: $autoLow)
                .tint(Theme.C.accent)
                .padding(.vertical, 10)
            Divider().overlay(Theme.C.divider)
            Toggle("画面ロック中は音声のみに切替", isOn: .constant(false))
                .disabled(true)
                .padding(.vertical, 10)
            Text("画面ロック中の音声のみ切替は、EPGStation 側の設定が必要なため未対応です")
                .font(Theme.F.caption).foregroundStyle(Theme.C.muted)
        }
        .font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)
    }
}
