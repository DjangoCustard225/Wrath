import Foundation
import Observation

/// Carries a link from outside the app, such as a Shortcuts action, to the add-link screen.
@Observable @MainActor public final class LinkHandoff {
    public static let shared = LinkHandoff()

    public private(set) var pending: URL?

    public init() {}

    /// Parses shared text with the same rules as pasting, keeping only the latest link.
    @discardableResult public func send(_ text: String) -> Bool {
        guard let url = LinkInput.parse(text) else { return false }
        pending = url
        return true
    }

    /// Returns the waiting link once, so it opens a single add-link screen.
    public func take() -> URL? {
        defer { pending = nil }
        return pending
    }
}
