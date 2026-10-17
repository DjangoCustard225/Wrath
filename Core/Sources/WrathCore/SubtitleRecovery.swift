import Foundation

public enum SubtitleRecovery {
    public static let warning = "Saved without subtitles"
    public struct Output: Sendable {
        public let url: URL
        public let warning: String?
    }
    public static func finish(subtitle: MediaSubtitle?, process: (MediaSubtitle?) async throws -> URL) async throws
        -> Output
    {
        try Task.checkCancellation()
        do {
            return Output(url: try await process(subtitle), warning: nil)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            guard subtitle != nil, error.localizedDescription.hasPrefix("Subtitle embedding:") else { throw error }
            return Output(url: try await process(nil), warning: warning)
        }
    }
}
