import SwiftUI

/// 番組詳細の「毎週録画ルール」。キーワード・曜日・時間帯・局から EPGStation のルール（`POST /api/rules`）を作る。
/// 既存ルールの実際の形（キーワード + channelIds + times[week,start,range]）に合わせてある
struct RuleSheet: View {
    let selection: GuideSelection
    @EnvironmentObject private var reserves: ReserveStore
    @Environment(\.dismiss) private var dismiss

    @State private var keyword: String
    @State private var week: Int
    @State private var limitTime: Bool
    @State private var startHour: Int
    @State private var rangeHours: Int
    @State private var sameChannelOnly = true
    @State private var avoidDuplicate = true
    @State private var message: String?
    @State private var created = false

    private static let dayNames = ["日", "月", "火", "水", "木", "金", "土"]

    init(selection: GuideSelection) {
        self.selection = selection
        let p = selection.program
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let weekday = cal.component(.weekday, from: p.start)      // 1 = 日曜
        let hour = cal.component(.hour, from: p.start)
        _keyword = State(initialValue: Self.suggestKeyword(p.name))
        _week = State(initialValue: 1 << (weekday - 1))
        // EPGStation の開始時刻は 1〜23。0 時台の番組は時間で絞らない
        _limitTime = State(initialValue: hour != 0)
        _startHour = State(initialValue: max(hour, 1))
        _rangeHours = State(initialValue: max(Int(ceil(p.durationMinutes / 60)), 1))
    }

    /// 番組名から「毎回同じ部分」を取り出す: [字] 等の記号、【サブタイトル】、▽以降、＃話数 を落とす
    static func suggestKeyword(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "【[^】]*】", with: "", options: .regularExpression)
        for sep in ["▽", "▼", "＃", "#"] {
            if let r = s.range(of: sep), s.distance(from: s.startIndex, to: r.lowerBound) >= 3 {
                s = String(s[..<r.lowerBound])
            }
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " 　"))
    }

    private var channel: ESChannel { selection.channel }
    private var canCreate: Bool { !keyword.trimmingCharacters(in: .whitespaces).isEmpty && week != 0 && !reserves.busy && !created }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("毎週録画ルール").font(Theme.F.sheetTitle).foregroundStyle(Theme.C.text)
                        Spacer()
                        CircleButton(systemName: "xmark", size: 36) { dismiss() }
                    }

                    section("キーワード（番組名に含む語）") {
                        TextField("番組名", text: $keyword)
                            .font(Theme.F.jp(15)).foregroundStyle(Theme.C.text)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 12).frame(height: 44)
                            .background(Theme.C.row, in: RoundedRectangle(cornerRadius: Theme.R.button))
                            .overlay(RoundedRectangle(cornerRadius: Theme.R.button).stroke(Theme.C.border))
                    }

                    section("曜日") {
                        HStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { i in
                                let bit = 1 << i
                                Button { week ^= bit } label: {
                                    Text(Self.dayNames[i]).font(Theme.F.jp(14, .bold))
                                        .frame(maxWidth: .infinity, minHeight: 40)
                                        .foregroundStyle(week & bit != 0 ? Theme.C.onAccent : Theme.C.text2)
                                        .background(week & bit != 0 ? Theme.C.accent : Theme.C.row,
                                                    in: RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(week & bit != 0 ? Color.clear : Theme.C.border))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    section("時間帯") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("開始時刻で絞る", isOn: $limitTime).tint(Theme.C.accent)
                            if limitTime {
                                Stepper("\(startHour) 時台から", value: $startHour, in: 1...23)
                                Stepper("\(rangeHours) 時間の範囲", value: $rangeHours, in: 1...12)
                            }
                        }
                        .font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)
                    }

                    section("放送局") {
                        Toggle("この局だけ（\(channel.name)）", isOn: $sameChannelOnly).tint(Theme.C.accent)
                            .font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)
                        if !sameChannelOnly {
                            Text("\(channel.channelType ?? "") の全局が対象になります").font(Theme.F.caption).foregroundStyle(Theme.C.warnText)
                        }
                    }

                    Toggle("同じ番組の重複予約を避ける", isOn: $avoidDuplicate).tint(Theme.C.accent)
                        .font(Theme.F.jp(14)).foregroundStyle(Theme.C.text)

                    Text("作ったルールは、録画タブの「ルール」で確認・削除できます。予約はサーバーが順に追加します。")
                        .font(Theme.F.caption).foregroundStyle(Theme.C.text4)
                }
                .padding(20)
            }

            VStack(spacing: 8) {
                if let message {
                    Text(message).font(Theme.F.caption).foregroundStyle(created ? Theme.C.live : Theme.C.rec)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { Task { await create() } } label: {
                    Text(created ? "作成しました" : "ルールを作成").font(Theme.F.jp(16, .bold)).foregroundStyle(Theme.C.onRec)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.C.rec, in: RoundedRectangle(cornerRadius: Theme.R.card))
                        .opacity(canCreate ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!canCreate)
            }
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 16)
            .background(Theme.C.surface)
        }
        .background(Theme.C.surface.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationCornerRadius(Theme.R.sheet)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.F.section).foregroundStyle(Theme.C.text)
            content()
        }
    }

    private func create() async {
        let rule = EPGStationClient.NewRule(
            keyword: keyword.trimmingCharacters(in: .whitespaces),
            channelId: sameChannelOnly ? channel.id : nil,
            channelType: channel.channelType ?? "GR",
            weekMask: week,
            startHour: limitTime ? startHour : nil,
            rangeHours: rangeHours,
            avoidDuplicate: avoidDuplicate)
        if let err = await reserves.addRule(rule) {
            message = err
        } else {
            created = true
            message = "ルールを作成しました。予約は順次追加されます"
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dismiss()
        }
    }
}
