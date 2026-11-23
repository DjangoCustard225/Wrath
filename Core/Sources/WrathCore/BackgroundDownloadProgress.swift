import Foundation

/// Progress for the entire download, including local processing and publishing.
/// Unknown transfer sizes stay indeterminate rather than inventing a percentage.
public struct BackgroundDownloadProgress: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let total: Int64
    public let completed: Int64

    public init(
        title: String, state: JobState, fraction: Double, known: Bool,
        phase: ProcessingPhase, paused: Bool, receivedBytes: Int64,
        speed: Double = 0, eta: Double? = nil, hideDetails: Bool = false
    ) {
        self.title = hideDetails ? "Wrath download" : title
        let value = fraction.isFinite ? min(1, max(0, fraction)) : 0
        switch state {
        case .queued, .resolving:
            subtitle = "Finding media"
            total = -1
            completed = 0
        case .downloading:
            var parts: [String]
            if paused {
                parts = ["Paused"]
            } else if known {
                parts = ["Downloading", "\(Int(value * 100))%"]
            } else {
                parts = [
                    "Downloading", ByteCountFormatter.string(fromByteCount: max(0, receivedBytes), countStyle: .file),
                ]
            }
            if !paused, speed.isFinite, speed > 0 {
                parts.append(
                    ByteCountFormatter.string(fromByteCount: Int64(min(speed, 1e15)), countStyle: .file) + "/s")
            }
            if !paused, known, let eta, eta.isFinite, eta > 0 {
                let seconds = Int(min(eta.rounded(.up), 31_536_000))
                if seconds >= 3600 {
                    parts.append("\(seconds / 3600)h \(seconds % 3600 / 60)m left")
                } else if seconds >= 60 {
                    parts.append("\(seconds / 60)m \(seconds % 60)s left")
                } else {
                    parts.append("\(seconds)s left")
                }
            }
            subtitle = parts.joined(separator: " · ")
            total = known ? 1_000 : -1
            completed = known ? Int64(value * 900) : max(0, receivedBytes)
        case .processing:
            subtitle = paused ? "Paused" : phase.label
            total = 1_000
            // Processing can retry without artwork/subtitles and its substeps
            // need not arrive in enum order. The session prevents regressions.
            completed = phase == .saving ? 990 : 900 + Int64(known ? value * 80 : 0)
        case .completed:
            subtitle = "Saved to Library"
            total = 1_000
            completed = 1_000
        case .failed, .cancelled:
            subtitle = state == .cancelled ? "Cancelled" : "Download stopped"
            total = 1_000
            completed = 0
        }
    }

    /// iOS expires continued processing tasks whose progress looks stalled, but
    /// merging, embedding artwork and saving report no progress. Each stalled
    /// heartbeat moves the count forward a little without ever finishing it.
    public static func heartbeat(completed: Int64, total: Int64) -> Int64 {
        guard total > 0 else { return completed + 1 }
        guard completed < total - 1 else { return completed }
        let step = max(1, (total - completed) / 50)
        return min(total - 1, completed + step)
    }
}
