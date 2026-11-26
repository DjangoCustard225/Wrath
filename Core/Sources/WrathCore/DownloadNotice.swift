import Foundation

/// The notification shown when a download finishes while Wrath is in the background.
public struct DownloadNotice: Equatable, Sendable {
    public let title: String
    public let body: String

    /// With App Lock on, the notice never names the media or repeats the error, which can include the link.
    public init(state: JobState, mediaTitle: String, error: String?, hideDetails: Bool) {
        let succeeded = state == .completed
        title = succeeded ? "Download finished" : "Download failed"
        if hideDetails {
            body = succeeded ? "Saved to your Wrath library." : "Open Wrath to see what went wrong."
        } else if succeeded {
            body = mediaTitle
        } else {
            let reason = error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            body = reason.isEmpty ? mediaTitle : String(reason.prefix(300))
        }
    }
}
