import Foundation
import Observation

/// Choices made in the share sheet before Wrath opens.
public struct SharePreset: Equatable, Hashable, Sendable {
    /// Video or audio; galleries are detected after the link is checked.
    public var kind: MediaKind?
    public var quality: Quality?
    /// Start downloading once the link is checked, instead of showing the options page.
    public var startNow: Bool

    public init(kind: MediaKind? = nil, quality: Quality? = nil, startNow: Bool = false) {
        self.kind = kind == .images ? nil : kind
        self.quality = quality
        self.startNow = startNow
    }

    public static let none = SharePreset()
}

/// A link waiting for the add-link screen, with any share sheet choices.
public struct SharedLink: Equatable, Hashable, Sendable {
    public let url: URL
    public let preset: SharePreset

    public init(url: URL, preset: SharePreset = .none) {
        self.url = url
        self.preset = preset
    }
}

/// Carries a link from outside the app, such as a Shortcuts action or the share sheet, to the add-link screen.
@Observable @MainActor public final class LinkHandoff {
    public static let shared = LinkHandoff()

    public private(set) var pending: SharedLink?

    public init() {}

    /// Parses shared text with the same rules as pasting, keeping only the latest link.
    @discardableResult public func send(_ text: String, preset: SharePreset = .none) -> Bool {
        guard let url = LinkInput.parse(text) else { return false }
        pending = SharedLink(url: url, preset: preset)
        return true
    }

    /// Accepts `wrath://add?link=…` from the share extension; any other app link is ignored.
    @discardableResult public func receive(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == Self.scheme, url.host() == "add",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let text = items.first(where: { $0.name == "link" })?.value
        else { return false }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let preset = SharePreset(
            kind: value("kind").flatMap(MediaKind.init(rawValue:)),
            quality: value("quality").flatMap(Int.init).flatMap(Quality.init(rawValue:)),
            startNow: value("start") == "1")
        return send(text, preset: preset)
    }

    /// The app link the share extension opens to hand over shared text and its choices.
    public nonisolated static func appURL(for text: String, preset: SharePreset = .none) -> URL? {
        let value = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumSharedLength))
        // Encoding everything but letters and digits keeps `&`, `=`, `+` and `#` intact on every platform.
        guard !value.isEmpty, let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        var query = "link=\(encoded)"
        if let kind = preset.kind { query += "&kind=\(kind.rawValue)" }
        if let quality = preset.quality { query += "&quality=\(quality.rawValue)" }
        if preset.startNow { query += "&start=1" }
        return URL(string: "\(scheme)://add?\(query)")
    }

    public nonisolated static let scheme = "wrath"
    /// Long enough for a caption with a link; longer shared text is not a link to download.
    nonisolated static let maximumSharedLength = 4096

    /// Returns the waiting link once, so it opens a single add-link screen.
    public func take() -> SharedLink? {
        defer { pending = nil }
        return pending
    }
}
