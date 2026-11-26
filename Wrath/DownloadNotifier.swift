import UIKit
import UserNotifications
import WrathCore

/// Notifies when a download finishes or fails while Wrath is in the background.
@MainActor enum DownloadNotifier {
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: PreferenceKey.notifyWhenFinished) as? Bool ?? true
    }

    /// Asks once, when a download starts, so the prompt arrives with context.
    static func requestPermissionIfNeeded() {
        guard isEnabled else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func post(for job: DownloadJob, hideDetails: Bool) {
        guard isEnabled, job.state == .completed || job.state == .failed,
            UIApplication.shared.applicationState != .active
        else { return }
        let notice = DownloadNotice(state: job.state, mediaTitle: job.title, error: job.error, hideDetails: hideDetails)
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "download-" + job.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
