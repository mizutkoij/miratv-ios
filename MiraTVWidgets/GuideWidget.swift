import SwiftUI
import WidgetKit

// ホーム画面・ロック画面のウィジェット: 「次の録画」と「いま放送中（地上波）」。
// ウィジェットはアプリの設定を読めない（App Group を使うと署名が面倒になる）ので、EPGStation の URL は
// アプリの既定値（Defaults.epgstationURL と同じ）を使う。Tailscale がつながっていないと「つながりません」になる

private let epgstationURL = URL(string: "http://192.0.2.10:8888")!
private let accent = Color(red: 0x3D / 255, green: 0xD6 / 255, blue: 0x8C / 255)
private let recRed = Color(red: 0xFF / 255, green: 0x5A / 255, blue: 0x5F / 255)

// MARK: - データ（アプリの型はこちらに無いので、必要なところだけ）

private struct WChannel: Decodable { let id: Int; let name: String; let channelType: String?; let remoteControlKeyId: Int? }
private struct WProgram: Decodable { let id: Int64; let channelId: Int; let startAt: Int64; let endAt: Int64; let name: String? }
private struct WSchedule: Decodable { let channel: WChannel; let programs: [WProgram] }
private struct WReserve: Decodable { let id: Int; let channelId: Int; let startAt: Int64; let endAt: Int64; let name: String?; let isSkip: Bool? }
private struct WReserves: Decodable { let reserves: [WReserve] }

struct GuideEntry: TimelineEntry {
    struct Item: Hashable { let channel: String; let title: String; let start: Date; let end: Date }
    let date: Date
    let next: Item?
    let recording: Item?       // いま録画中
    let onAir: [Item]
    let error: String?
}

struct GuideProvider: TimelineProvider {
    func placeholder(in context: Context) -> GuideEntry {
        let now = Date()
        let it = GuideEntry.Item(channel: "NHK総合", title: "ニュース", start: now, end: now.addingTimeInterval(1800))
        return GuideEntry(date: now, next: it, recording: nil, onAir: [it, it, it, it], error: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (GuideEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task { completion(await load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GuideEntry>) -> Void) {
        Task {
            let e = await load()
            // 次に番組が替わる時刻（遅くとも 30 分後、つながらなかったら 15 分後）に取り直す
            let ends = e.onAir.map(\.end) + [e.next?.start, e.recording?.end].compactMap { $0 }
            let soonest = ends.filter { $0 > Date() }.min() ?? Date().addingTimeInterval(1800)
            let refresh = e.error != nil ? Date().addingTimeInterval(900)
                : min(soonest.addingTimeInterval(30), Date().addingTimeInterval(1800))
            completion(Timeline(entries: [e], policy: .after(refresh)))
        }
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        var c = URLComponents(url: epgstationURL.appending(path: path), resolvingAgainstBaseURL: false)!
        c.queryItems = query
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func load() async -> GuideEntry {
        let now = Date()
        do {
            async let sch: [WSchedule] = get("api/schedules/broadcasting", [URLQueryItem(name: "isHalfWidth", value: "true")])
            // type=normal: 重複・競合・スキップで録画されない予約を除く
            async let res: WReserves = get("api/reserves", [URLQueryItem(name: "isHalfWidth", value: "true"),
                                                             URLQueryItem(name: "type", value: "normal"),
                                                             URLQueryItem(name: "limit", value: "50")])
            let schedules = try await sch
            var reserveError: String?
            var reserves: [WReserve] = []
            do { reserves = try await res.reserves } catch { reserveError = "予約を読めません" }
            let names = Dictionary(schedules.map { ($0.channel.id, $0.channel.name) }, uniquingKeysWith: { a, _ in a })
            func item(_ ch: Int, _ name: String?, _ s: Int64, _ e: Int64) -> GuideEntry.Item {
                .init(channel: names[ch] ?? "", title: name ?? "", start: Date(timeIntervalSince1970: Double(s) / 1000),
                      end: Date(timeIntervalSince1970: Double(e) / 1000))
            }
            let gr = schedules
                .filter { $0.channel.channelType == "GR" }
                .sorted { ($0.channel.remoteControlKeyId ?? 99) < ($1.channel.remoteControlKeyId ?? 99) }
            var seen = Set<Int>()                  // サブチャンネルなど、同じリモコン番号は 1 つだけ
            let onAir = gr.compactMap { s -> GuideEntry.Item? in
                guard let p = s.programs.first, seen.insert(s.channel.remoteControlKeyId ?? s.channel.id).inserted else { return nil }
                return item(s.channel.id, p.name, p.startAt, p.endAt)
            }
            let nowMs = Int64(now.timeIntervalSince1970 * 1000)
            let active = reserves.filter { $0.isSkip != true }.sorted { $0.startAt < $1.startAt }
            let recording = active.first { $0.startAt <= nowMs && nowMs < $0.endAt }
            let next = active.first { $0.startAt > nowMs }
            return GuideEntry(date: now,
                              next: next.map { item($0.channelId, $0.name, $0.startAt, $0.endAt) },
                              recording: recording.map { item($0.channelId, $0.name, $0.startAt, $0.endAt) },
                              onAir: onAir, error: reserveError)
        } catch {
            return GuideEntry(date: now, next: nil, recording: nil, onAir: [], error: "EPGStation につながりません")
        }
    }
}

// MARK: - 見た目

private func hm(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ja_JP")
    f.timeZone = TimeZone(identifier: "Asia/Tokyo")
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M/d HH:mm"
    return f.string(from: d)
}

private struct ReserveLine: View {
    let label: String
    let item: GuideEntry.Item
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(.caption2.bold()).foregroundStyle(color)
                Text(hm(item.start)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(item.title).font(.caption.bold()).lineLimit(2)
            Text(item.channel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct GuideWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GuideEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                if let r = entry.recording {
                    Text("● 録画中").font(.caption2.bold())
                    Text(r.title).font(.caption).lineLimit(2)
                } else if let n = entry.next {
                    Text("次の録画 \(hm(n.start))").font(.caption2.bold())
                    Text(n.title).font(.caption).lineLimit(2)
                } else {
                    Text(entry.error ?? "録画の予定なし").font(.caption)
                }
            }
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                if let r = entry.recording { ReserveLine(label: "録画中", item: r, color: recRed) }
                if let n = entry.next { ReserveLine(label: "次の録画", item: n, color: accent) }
                if entry.recording == nil && entry.next == nil {
                    Text(entry.error ?? "録画の予定はありません").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    if let r = entry.recording { ReserveLine(label: "録画中", item: r, color: recRed) }
                    if let n = entry.next { ReserveLine(label: "次の録画", item: n, color: accent) }
                    if entry.recording == nil && entry.next == nil {
                        Text(entry.error ?? "録画の予定はありません").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 118, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text("いま放送中").font(.caption2.bold()).foregroundStyle(accent)
                    if let e = entry.error { Text(e).font(.caption2).foregroundStyle(.secondary) }
                    ForEach(Array(entry.onAir.prefix(family == .systemLarge ? 12 : 5).enumerated()), id: \.offset) { _, it in
                        HStack(spacing: 6) {
                            Text(it.channel).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 52, alignment: .leading)
                            Text(it.title).font(.caption2).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct GuideWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MiraTVGuide", provider: GuideProvider()) { entry in
            GuideWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("MiraTV")
        .description("次の録画と、いま放送中の番組（地上波）")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}
