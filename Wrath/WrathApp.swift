import SwiftUI
import WrathCore

@main struct WrathApp: App {
    @State private var store = DownloadStore()
    var body: some Scene { WindowGroup { WrathRoot(store: store).tint(.orange) } }
}

private enum AppTab { case downloads, library, settings }

struct WrathRoot: View {
    @Bindable var store: DownloadStore
    @State private var tab = AppTab.downloads
    @State private var adding = false
    @State private var incomingLink = ""
    @State private var reconnectSite: SocialPlatform?
    @State private var reconnectURL: URL?
    @State private var reconnectRevision: UUID?
    var body: some View {
        TabView(selection: $tab) {
            DownloadsView(store: store, adding: $adding)
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }.tag(AppTab.downloads)
            LibraryView(store: store)
                .tabItem { Label("Library", systemImage: "play.rectangle.on.rectangle") }.tag(AppTab.library)
            SettingsView(store: store)
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppTab.settings)
        }
        .wrathMinimizeTabs()
        .wrathSoftScrollEdges()
        .sheet(isPresented: $adding, onDismiss: { incomingLink = "" }) {
            AddLinkSheet(store: store, link: incomingLink) {
                tab = .downloads
                incomingLink = ""
            }
        }
        .sheet(
            item: $reconnectSite,
            onDismiss: {
                // A saved account causes link inspection to refresh, then lets the
                // user review formats before retrying the failed download.
                let changed = reconnectRevision != nil && SocialAccessStore.shared.revision != reconnectRevision
                let link = reconnectURL
                reconnectURL = nil
                reconnectRevision = nil
                store.failedSocialLink = nil
                if changed, let link { presentLink(link.absoluteString) }
            }
        ) { site in
            SocialLoginView(site: site)
        }
        .alert(
            "Wrath",
            isPresented: Binding(
                get: { store.message != nil },
                set: {
                    if !$0 {
                        store.message = nil
                        store.failedSocialLink = nil
                    }
                })
        ) {
            if let url = store.failedSocialLink, let site = SocialPlatform.forURL(url), site.supportsCookies {
                Button("Connect \(site.name)") {
                    reconnectURL = url
                    reconnectRevision = SocialAccessStore.shared.revision
                    store.message = nil
                    reconnectSite = site
                }
            }
            Button("OK") {
                store.message = nil
                store.failedSocialLink = nil
            }
        } message: {
            Text(store.message ?? "")
        }
        .onOpenURL { url in
            if url.scheme == "wrath", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                let value = components.queryItems?.first(where: { $0.name == "url" })?.value
            {
                presentLink(value)
            } else if LinkInput.parse(url.absoluteString) != nil {
                presentLink(url.absoluteString)
            }
        }
    }

    private func presentLink(_ value: String) {
        guard !store.isDownloadOccupied else {
            tab = .downloads
            store.message = "A download is already in progress. Wait for it to finish before adding another link."
            return
        }
        incomingLink = value
        adding = true
    }
}
