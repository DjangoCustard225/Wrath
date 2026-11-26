/// UserDefaults keys. Their values are persisted, so existing keys must never change.
enum PreferenceKey {
    static let mediaKind = "kind"
    static let quality = "quality"
    static let downloadOptions = "downloadOptions"
    static let librarySort = "librarySort"
    static let notifyWhenFinished = "notifyWhenFinished"
    static let suggestCopiedLinks = "suggestCopiedLinks"

    static func socialBrowserUserAgent(_ site: String) -> String { "socialBrowserUserAgent.\(site)" }
    /// Removed manual User-Agent override, deleted on launch.
    static func legacySocialUserAgent(_ site: String) -> String { "socialUserAgent.\(site)" }
}
