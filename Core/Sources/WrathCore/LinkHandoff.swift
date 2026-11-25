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

    /// Accepts `wrath://add?link=…` from the share extension; any other app link is ignored.
    @discardableResult public func receive(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == Self.scheme, url.host() == "add",
            let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "link" })?.value
        else { return false }
        return send(text)
    }

    /// The app link the share extension opens to hand over shared text.
    public nonisolated static func appURL(for text: String) -> URL? {
        let value = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumSharedLength))
        // Encoding everything but letters and digits keeps `&`, `=`, `+` and `#` intact on every platform.
        guard !value.isEmpty, let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        return URL(string: "\(scheme)://add?link=\(encoded)")
    }

    public nonisolated static let scheme = "wrath"
    /// Long enough for a caption with a link; longer shared text is not a link to download.
    nonisolated static let maximumSharedLength = 4096

    /// Returns the waiting link once, so it opens a single add-link screen.
    public func take() -> URL? {
        defer { pending = nil }
        return pending
    }
}
