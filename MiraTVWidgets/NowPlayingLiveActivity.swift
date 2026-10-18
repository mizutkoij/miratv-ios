import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MiraTVWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingLiveActivity()
    }
}

private let accent = Color(red: 0x3D / 255, green: 0xD6 / 255, blue: 0x8C / 255)

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    KindIcon(state: s).font(.title3).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimeText(state: s).font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(s.title.isEmpty ? s.channel : s.title).font(.subheadline.bold()).lineLimit(1)
                        Text(s.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Bar(state: s).padding(.horizontal, 6)
                }
            } compactLeading: {
                KindIcon(state: s)
            } compactTrailing: {
                Text(shortChannel(s.channel)).font(.caption2.bold()).lineLimit(1).frame(maxWidth: 64)
            } minimal: {
                KindIcon(state: s)
            }
        }
    }
}

/// 局名の頭（Dynamic Island の右は狭い）
private func shortChannel(_ s: String) -> String {
    let t = s.replacingOccurrences(of: "テレビ", with: "").trimmingCharacters(in: .whitespaces)
    return String((t.isEmpty ? s : t).prefix(5))
}

private struct KindIcon: View {
    let state: NowPlayingAttributes.ContentState
    var body: some View {
        Image(systemName: state.isPaused ? "pause.fill" : (state.kind == .recorded ? "play.rectangle.fill" : "tv.fill"))
            .foregroundStyle(state.kind == .live && !state.isPaused ? accent : .white)
    }
}

private struct TimeText: View {
    let state: NowPlayingAttributes.ContentState
    var body: some View {
        if state.kind == .live {
            Text("LIVE").foregroundStyle(accent)
        } else if state.kind == .timeshift, let b = state.behindSeconds {
            Text("-\(Int(b) / 60):\(String(format: "%02d", Int(b) % 60))")
        } else if !state.isPaused, let end = state.end, case let now = Date(), end > now {
            Text(timerInterval: now...end, countsDown: true)
        } else {
            Text(state.isPaused ? "停止中" : "")
        }
    }
}

private struct Bar: View {
    let state: NowPlayingAttributes.ContentState
    var body: some View {
        if let start = state.start, let end = state.end, end > start {
            if state.isPaused {
                ProgressView(value: min(max(state.pausedProgress ?? 0, 0), 1)).tint(.white)
            } else {
                ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(state.kind == .live ? accent : .white)
            }
        }
    }
}

private struct LockScreenView: View {
    let state: NowPlayingAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                KindIcon(state: state).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title.isEmpty ? state.channel : state.title).font(.headline).lineLimit(1)
                    Text(state.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                TimeText(state: state).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Bar(state: state)
        }
        .foregroundStyle(.white)
    }
}
