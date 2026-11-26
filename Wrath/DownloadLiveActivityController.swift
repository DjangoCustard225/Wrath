@preconcurrency import ActivityKit
import Foundation
import WrathActivityShared
import WrathCore

/// Shows download progress on the Lock Screen and in the Dynamic Island when iOS isn't already showing its
/// own continued-processing progress for the download (iOS 17–25, or when iOS 26 declines continued work).
@MainActor final class DownloadLiveActivityController {
    private typealias State = DownloadActivityAttributes.ContentState
    private var activity: Activity<DownloadActivityAttributes>?
    private var unavailable = false
    private var latest: State?
    private var lastUpdate: TimeInterval = 0

    func update(_ progress: BackgroundDownloadProgress) {
        let state = Self.state(progress)
        guard let activity else {
            start(with: state)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard state != latest, now - lastUpdate >= 1 else { return }
        latest = state
        lastUpdate = now
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// Ends the activity, leaving the result visible for a while if Wrath is in the background.
    func end(_ progress: BackgroundDownloadProgress, cancelled: Bool, inForeground: Bool) {
        guard let activity else { return }
        self.activity = nil
        latest = nil
        let state = Self.state(progress, finished: true)
        let policy: ActivityUIDismissalPolicy = cancelled || inForeground ? .immediate : .after(.now + 15 * 60)
        Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy) }
    }

    private func start(with state: State) {
        // Activities can only start while Wrath is in the foreground, which is when downloads begin.
        guard !unavailable, ActivityAuthorizationInfo().areActivitiesEnabled else {
            unavailable = true
            return
        }
        do {
            activity = try Activity.request(
                attributes: DownloadActivityAttributes(), content: ActivityContent(state: state, staleDate: nil))
            latest = state
            lastUpdate = ProcessInfo.processInfo.systemUptime
        } catch {
            unavailable = true
        }
    }

    private static func state(_ progress: BackgroundDownloadProgress, finished: Bool = false) -> State {
        State(
            title: progress.title, status: progress.subtitle,
            fraction: progress.total > 0 ? Double(progress.completed) / Double(progress.total) : nil,
            finished: finished && progress.completed == progress.total && progress.total > 0)
    }
}
