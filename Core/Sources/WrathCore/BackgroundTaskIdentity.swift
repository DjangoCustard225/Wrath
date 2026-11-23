import Foundation

/// iOS only launches a continued processing task whose identifier starts with the
/// running bundle identifier and is listed in BGTaskSchedulerPermittedIdentifiers.
/// Sideloading tools often append a suffix to the bundle identifier, so neither
/// can be hardcoded.
public enum BackgroundTaskIdentity {
    public static let originalBundleIdentifier = "app.wrath.downloader"
    public static let infoKey = "BGTaskSchedulerPermittedIdentifiers"

    public static func prefix(bundleIdentifier: String?) -> String {
        let base = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? originalBundleIdentifier
        return base + ".download."
    }

    /// The Info.plist wildcard that permits every identifier with this prefix.
    public static func wildcard(bundleIdentifier: String?) -> String {
        prefix(bundleIdentifier: bundleIdentifier) + "*"
    }

    /// Matches the scheduler's rules: exact entries, or a trailing `*` wildcard.
    public static func isPermitted(_ identifier: String, by permitted: [String]) -> Bool {
        permitted.contains { entry in
            if entry.hasSuffix("*") { return identifier.hasPrefix(String(entry.dropLast())) }
            return entry == identifier
        }
    }

    /// Adds the wildcard for `runningIdentifier` and restores the original bundle
    /// identifier, so a sideloading tool applies the same suffix again on install.
    /// App extension identifiers that carry the running prefix are restored too.
    public static func patchedInfo(_ info: [String: Any], runningIdentifier: String) -> [String: Any] {
        var info = info
        info["CFBundleIdentifier"] = originalBundleIdentifier
        var permitted = info[infoKey] as? [String] ?? []
        let entry = wildcard(bundleIdentifier: runningIdentifier)
        if !permitted.contains(entry) { permitted.append(entry) }
        info[infoKey] = permitted
        return info
    }

    public static func patchedExtensionInfo(_ info: [String: Any], runningIdentifier: String) -> [String: Any] {
        guard let identifier = info["CFBundleIdentifier"] as? String, identifier.hasPrefix(runningIdentifier + ".")
        else { return info }
        var info = info
        info["CFBundleIdentifier"] = originalBundleIdentifier + identifier.dropFirst(runningIdentifier.count)
        return info
    }
}
