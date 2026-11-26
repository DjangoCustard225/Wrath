import BackgroundTasks
import Foundation
import UIKit
import WrathCore

/// One session owns both permission to run and the system's progress activity.
/// yt-dlp and FFmpeg remain on their existing worker queues.
@MainActor final class DownloadBackgroundSession {
    private var identifier: String?
    private var continuedTask: BGTask?
    private var shortTask: UIBackgroundTaskIdentifier = .invalid
    private var waiting: CheckedContinuation<String?, Error>?
    private var expiration: (() -> Void)?
    private var launchTimeout: Task<Void, Never>?
    private var finished = false
    private var latest: BackgroundDownloadProgress?
    private var lastUpdate: TimeInterval = 0
    private var lastAdvance: TimeInterval = 0
    private static let heartbeatInterval: TimeInterval = 3

    /// Whether iOS is showing its own continued-processing progress for this download.
    var showsSystemProgress: Bool { continuedTask != nil }

    /// Returns a user-facing notice only when iOS 26 declines continued work.
    func begin(id: UUID, title: String, onExpiration: @escaping () -> Void) async throws -> String? {
        try Task.checkCancellation()
        expiration = onExpiration
        if #available(iOS 26, *) {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiting = continuation
                    submit(id: id, title: title)
                }
            } onCancel: {
                Task { @MainActor in self.finish(success: false) }
            }
        }
        beginLimitedTime()
        return nil
    }

    @available(iOS 26, *)
    private func submit(id: UUID, title: String) {
        // Never expose a media title while permission and privacy changes race.
        // The first progress update supplies a title only if app lock is off.
        let title = BackgroundDownloadProgress.privateTitle
        // Exact, unique registrations avoid duplicate-handler crashes and stale
        // callbacks being attached to a later download. Continued tasks may be
        // registered after app launch; Info.plist must permit this identifier family.
        // The prefix follows the running bundle identifier, which sideloading
        // tools may have changed.
        let name = BackgroundTaskSetup.prefix + id.uuidString
        guard BackgroundTaskSetup.permits(name) else {
            // Registering an identifier Info.plist does not permit raises an exception.
            useForegroundFallback(notice: BackgroundTaskSetup.unpermittedNotice)
            return
        }
        identifier = name
        let scheduler = BGTaskScheduler.shared
        guard
            scheduler.register(
                forTaskWithIdentifier: name, using: .main,
                launchHandler: { [weak self] task in
                    MainActor.assumeIsolated {
                        guard let self, !self.finished, self.waiting != nil,
                            let task = task as? BGContinuedProcessingTask
                        else {
                            task.setTaskCompleted(success: false)
                            return
                        }
                        self.continuedTask = task
                        self.launchTimeout?.cancel()
                        self.launchTimeout = nil
                        task.expirationHandler = { [weak self] in
                            Task { @MainActor in self?.expire() }
                        }
                        task.progress.totalUnitCount = -1
                        task.progress.completedUnitCount = 0
                        self.lastAdvance = ProcessInfo.processInfo.systemUptime
                        let continuation = self.waiting
                        self.waiting = nil
                        continuation?.resume(returning: nil)
                    }
                })
        else {
            useForegroundFallback()
            return
        }
        launchTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            // An immediate request must not leave the download screen waiting
            // forever if the system fails to deliver its launch callback.
            self?.useForegroundFallback()
        }
        if #available(iOS 27, *) {
            // iOS 27's completion API reports failures the older throwing API
            // cannot capture. Apple asks callers to submit off the main thread.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let request = BGContinuedProcessingTaskRequest(
                    identifier: name, title: title, subtitle: "Finding media")
                request.strategy = .fail
                BGTaskScheduler.shared.submitTaskRequest(request) { [weak self] error in
                    Task { @MainActor in
                        guard let self, !self.finished else {
                            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: name)
                            return
                        }
                        if error != nil { self.useForegroundFallback() }
                    }
                }
            }
        } else {
            let request = BGContinuedProcessingTaskRequest(
                identifier: name, title: title, subtitle: "Finding media")
            // Wrath supports one immediate download, never deferred downloads.
            request.strategy = .fail
            do {
                try scheduler.submit(request)
            } catch {
                useForegroundFallback()
            }
        }
    }

    private func useForegroundFallback(
        notice: String = "Background downloading is unavailable. Keep Wrath open for this download."
    ) {
        guard !finished, waiting != nil else { return }
        launchTimeout?.cancel()
        launchTimeout = nil
        if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        identifier = nil
        beginLimitedTime()
        let continuation = waiting
        waiting = nil
        continuation?.resume(returning: notice)
    }

    private func beginLimitedTime() {
        shortTask = UIApplication.shared.beginBackgroundTask(withName: "Finish media download") { [weak self] in
            Task { @MainActor in self?.expire() }
        }
    }

    private func expire() {
        guard !finished else { return }
        expiration?()
        // Cancellation reaches the Python/FFmpeg token before releasing the
        // assertion. Completion is idempotent when the worker unwinds afterward.
        finish(success: false)
    }

    func update(_ snapshot: BackgroundDownloadProgress) {
        guard !finished, #available(iOS 26, *),
            let task = continuedTask as? BGContinuedProcessingTask
        else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard latest == nil || now - lastUpdate >= 0.5 else { return }
        let sameScale = latest?.total == snapshot.total
        let previous = task.progress.completedUnitCount
        var completed = sameScale ? max(previous, snapshot.completed) : snapshot.completed
        if sameScale, completed <= previous, now - lastAdvance >= Self.heartbeatInterval {
            completed = BackgroundDownloadProgress.heartbeat(completed: previous, total: snapshot.total)
        }
        if !sameScale || completed > previous { lastAdvance = now }
        // Reset bytes before switching to a bounded work-unit total. Otherwise
        // observers can briefly see >100% and treat an unfinished task as done.
        if !sameScale { task.progress.completedUnitCount = 0 }
        task.progress.totalUnitCount = snapshot.total
        task.progress.completedUnitCount = completed
        if latest?.title != snapshot.title || latest?.subtitle != snapshot.subtitle {
            task.updateTitle(snapshot.title, subtitle: snapshot.subtitle)
        }
        latest = snapshot
        lastUpdate = now
    }

    func redactMediaDetails() {
        guard #available(iOS 26, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
        task.updateTitle(BackgroundDownloadProgress.privateTitle, subtitle: latest?.subtitle ?? "Finding media")
        lastUpdate = 0
    }

    func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        launchTimeout?.cancel()
        launchTimeout = nil
        expiration = nil
        let continuation = waiting
        waiting = nil
        continuation?.resume(throwing: CancellationError())
        if let task = continuedTask {
            if #available(iOS 26, *), let task = task as? BGContinuedProcessingTask, success {
                task.progress.totalUnitCount = 1_000
                task.progress.completedUnitCount = 1_000
                task.updateTitle(
                    AppLockServices.controller.isEnabled ? BackgroundDownloadProgress.privateTitle : task.title,
                    subtitle: "Saved to Library")
            }
            task.setTaskCompleted(success: success)
            continuedTask = nil
        } else if let identifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        identifier = nil
        if shortTask != .invalid {
            UIApplication.shared.endBackgroundTask(shortTask)
            shortTask = .invalid
        }
    }
}
