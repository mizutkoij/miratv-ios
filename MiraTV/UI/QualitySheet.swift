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

    /// ワンセグ（地上波のみ）。同じ電波に最初から入っている低解像度の放送をそのまま受ける。
    /// サーバーは何も変換しない（Mirakurun が同じチューナーから取り出すだけ）
    static let oneSeg = PlaybackChoice(
        id: -3, title: "ワンセグ", source: "Mirakurun",
        spec: "H.264 · 320×180 前後 · 約0.3〜0.5Mbps（変換なし）", abilities: "モバイル回線向け · データ放送× 画質は低い")

    /// 音声のみ。relay = 自前の中継（streamd）が映像のパケットを捨てて送る（エンコードなし・通信量 約 1/50）。
    /// 中継が無ければ、原画質のストリームを受けて端末側で映像を捨てる（通信量は原画質と同じ）
    static func audioOnly(relay: Bool) -> PlaybackChoice {
        relay
            ? PlaybackChoice(id: -2, title: "音声のみ", source: "streamd",
                             spec: "AAC · 映像を中継で除去 · 約0.3Mbps（エンコードなし）", abilities: "モバイル回線向け · 字幕◯ 主/副音声◯")
            : PlaybackChoice(id: -2, title: "音声のみ", source: "Mirakurun",
                             spec: "AAC · 映像はデコードしない · 通信量は原画質と同じ", abilities: "電池の節約 · 字幕◯ 主/副音声◯")
    }

    /// 中継が無くても、地上波ならワンセグの音声で軽くできる（音質はワンセグ相当）
    static let audioOnlyOneSeg = PlaybackChoice(
        id: -2, title: "音声のみ", source: "Mirakurun（ワンセグ）",
        spec: "HE-AAC · ワンセグの音声 · 約0.3Mbps（変換なし）", abilities: "モバイル回線向け · 音質はワンセグ相当")

    /// id 1000 以上 = EPGStation の変換 M2TS（index は ESLiveHLSModes.m2tsNames の位置）
    static let m2tsBase = 1000

    static func fromM2TS(_ names: [String]) -> [PlaybackChoice] {
        names.enumerated().map { i, name in
            PlaybackChoice(
                id: m2tsBase + i,
                title: "変換（TS）",
                source: "EPGStation",
                spec: "\(name) · 端末の再生エンジン",
                abilities: "字幕◯（変換の設定で字幕を残していれば） データ放送×")
        }
    }

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
    /// 設定「サーバーで変換する再生モードを使う」
    let transcodeAllowed: Bool
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
                    if !transcodeAllowed {
                        Text("サーバーに負荷をかけないよう、変換配信（EPGStation の ffmpeg）は使わない設定です。設定の「サーバーで変換する再生モードを使う」で変えられます")
                            .font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                    } else if loadingChoices {
                        Text("EPGStation の設定を確認中…").font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                    } else if choices.count <= 2 {
                        Text("EPGStation にライブ配信（HLS / M2TS の変換）の設定が無いため、変換の選択肢はありません。config.yml の stream.live を確認してください")
                            .font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                    }
                }
                if transcodeAllowed { toggles.padding(.top, 8) }
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
