import Foundation
import WrathCore

/// Checks whether this install can run continued processing tasks and, when a
/// sideloading tool changed the bundle identifier, exports a copy of the installed
/// app whose Info.plist permits the changed identifier.
enum BackgroundTaskSetup {
    static let prefix = BackgroundTaskIdentity.prefix(bundleIdentifier: Bundle.main.bundleIdentifier)

    static let unpermittedNotice =
        "Background downloading needs a one-time fix for this install. Keep Wrath open for this download, then see Settings › Background Downloads."

    static func permits(_ identifier: String) -> Bool {
        let permitted = Bundle.main.object(forInfoDictionaryKey: BackgroundTaskIdentity.infoKey) as? [String] ?? []
        return BackgroundTaskIdentity.isPermitted(identifier, by: permitted)
    }

    /// True when downloads cannot continue in the background until the app is reinstalled from a fixed copy.
    static var needsFix: Bool {
        guard #available(iOS 26, *) else { return false }
        return !permits(prefix + "check")
    }

    /// Builds `Wrath.ipa` from the installed bundle. Reinstalling it with the same
    /// sideloading tool restores the same bundle identifier, which the copy now permits.
    static func exportFixedApp(running: String, to directory: URL) throws -> URL {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("fixed-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: work) }
        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        try files.createDirectory(at: payload, withIntermediateDirectories: true)
        let app = payload.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent, isDirectory: true)
        try files.copyItem(at: Bundle.main.bundleURL, to: app)

        try updateInfo(in: app) { BackgroundTaskIdentity.patchedInfo($0, runningIdentifier: running) }
        let plugins = app.appendingPathComponent("PlugIns", isDirectory: true)
        for plugin in (try? files.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? []
        where plugin.pathExtension == "appex" {
            try updateInfo(in: plugin) { BackgroundTaskIdentity.patchedExtensionInfo($0, runningIdentifier: running) }
        }

        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("Wrath.ipa")
        try zip(payload, to: output)
        return output
    }

    private static func updateInfo(in bundle: URL, change: ([String: Any]) -> [String: Any]) throws {
        let url = bundle.appendingPathComponent("Info.plist")
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard
            let info = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), format: &format) as? [String: Any]
        else { throw CocoaError(.propertyListReadCorrupt) }
        // The installed bundle is read-only and the copy keeps its permissions.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try PropertyListSerialization.data(fromPropertyList: change(info), format: format, options: 0)
            .write(to: url, options: .atomic)
    }

    /// The system archiver keeps `Payload` as the archive's top-level folder.
    private static func zip(_ folder: URL, to output: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zip in
            do {
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.copyItem(at: zip, to: output)
            } catch {
                copyError = error
            }
        }
        if let error = coordinatorError ?? copyError { throw error }
    }
}
