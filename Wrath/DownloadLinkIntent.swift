import AppIntents
import WrathCore

/// A Shortcuts and Siri action that opens Wrath with a link ready on the add-link screen.
struct DownloadLinkIntent: AppIntent {
    static var title: LocalizedStringResource { "Download with Wrath" }
    static var description: IntentDescription {
        IntentDescription("Opens Wrath with the link filled in, ready to choose a format and download.")
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Link", description: "A media link, or shared text that contains one.")
    var link: String

    static var parameterSummary: some ParameterSummary {
        Summary("Download \(\.$link) with Wrath")
    }

    @MainActor func perform() async throws -> some IntentResult {
        guard LinkHandoff.shared.send(link) else { throw DownloadLinkError.noLink }
        return .result()
    }
}

enum DownloadLinkError: Error, CustomLocalizedStringResourceConvertible {
    case noLink

    var localizedStringResource: LocalizedStringResource {
        "Wrath couldn’t find a media link in that input."
    }
}

/// Lists the action in Shortcuts, Spotlight and Siri without any setup.
struct WrathShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DownloadLinkIntent(),
            phrases: ["Download with \(.applicationName)", "Save a link with \(.applicationName)"],
            shortTitle: "Download Link", systemImageName: "arrow.down.circle")
    }
}
