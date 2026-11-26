import ActivityKit
import SwiftUI
import WidgetKit
import WrathActivityShared

@main struct WrathLiveActivityBundle: WidgetBundle {
    var body: some Widget { DownloadLiveActivity() }
}

/// Download progress on the Lock Screen and in the Dynamic Island. Tapping it opens Wrath's progress screen.
struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenProgress(state: context.state)
                .padding(16)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(.orange)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: symbol(context.state)).font(.title2).foregroundStyle(.orange)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let fraction = context.state.fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.headline.monospacedDigit()).padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        ProgressBar(fraction: context.state.fraction)
                        Text(context.state.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: symbol(context.state)).foregroundStyle(.orange)
            } compactTrailing: {
                ProgressRing(fraction: context.state.fraction).frame(width: 18, height: 18)
            } minimal: {
                ProgressRing(fraction: context.state.fraction).frame(width: 18, height: 18)
            }
            .keylineTint(.orange)
        }
    }
}

private func symbol(_ state: DownloadActivityAttributes.ContentState) -> String {
    state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill"
}

private struct LockScreenProgress: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol(state)).font(.system(size: 30)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(state.title).font(.headline).lineLimit(1)
                ProgressBar(fraction: state.fraction)
                Text(state.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct ProgressBar: View {
    let fraction: Double?

    var body: some View {
        if let fraction {
            ProgressView(value: fraction).tint(.orange)
        } else {
            ProgressView(value: 0.3).tint(.orange.opacity(0.4))
        }
    }
}

private struct ProgressRing: View {
    let fraction: Double?

    var body: some View {
        ZStack {
            Circle().stroke(.orange.opacity(0.3), lineWidth: 3)
            Circle().trim(from: 0, to: fraction ?? 0.25)
                .stroke(.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
