import Foundation

public enum ArtworkRecovery {
    public static let warning = "Saved without thumbnail"

    public struct Output: Sendable {
        public let url: URL
        public let warning: String?
    }

    /// Retry only local processing, retaining the downloaded tracks. If the
    /// original media also fails, propagate that error instead of reporting success.
    public static func finish(cover: URL?, process: (URL?) async throws -> URL) async throws -> Output {
        try Task.checkCancellation()
        do {
            return Output(url: try await process(cover), warning: nil)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            guard cover != nil else { throw error }
            return Output(url: try await process(nil), warning: warning)
        }
    }
}
