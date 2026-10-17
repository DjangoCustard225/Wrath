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
    var body: some View {
        TabView(selection: $tab) {
            Tab("Downloads", systemImage: "arrow.down.circle", value: .downloads) {
                DownloadsView(store: store, adding: $adding)
            }
            Tab("Library", systemImage: "play.rectangle.on.rectangle", value: .library) {
                LibraryView(store: store)
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) { SettingsView(store: store) }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .sheet(isPresented: $adding, onDismiss: { incomingLink = "" }) {
            AddLinkSheet(store: store, link: incomingLink) {
                tab = .downloads
                incomingLink = ""
            }
        }
        .alert("Wrath", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: {
            Text(store.message ?? "")
        }
        .onOpenURL { url in
            if url.scheme == "wrath", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                let value = components.queryItems?.first(where: { $0.name == "url" })?.value
            {
                incomingLink = value
                adding = true
            } else if LinkInput.parse(url.absoluteString) != nil {
                incomingLink = url.absoluteString
                adding = true
            }
        }
    }
}
