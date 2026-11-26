import SwiftUI
import WrathCore

@main struct WrathApp: App {
    @State private var store = DownloadStore()
    @State private var lock = AppLockServices.controller
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            WrathRoot(store: store).tint(.orange).environment(lock)
                .background(AppPrivacyShield(lock: lock, enabled: lock.isEnabled, locked: !lock.isUnlocked))
        }
        .onChange(of: phase) { _, phase in
            if phase == .background { lock.lock() }
        }
    }
}

private enum AppTab { case downloads, library, settings }

struct WrathRoot: View {
    @Bindable var store: DownloadStore
    @Environment(AppLockController.self) private var lock
    @State private var tab = AppTab.downloads
    @State private var presentation = AppSheetPresentation()
    @State private var handoff = LinkHandoff.shared
    @State private var copiedLink = CopiedLinkDetector.shared
    @Environment(\.scenePhase) private var phase
    @State private var progressItem: JobItem?
    @State private var reconnectURL: URL?
    @State private var reconnectRevision: UUID?
    var body: some View {
        TabView(selection: $tab) {
            DownloadsView(
                store: store, add: { presentation.present(.addLink) },
                showProgress: showProgress, copiedLink: copiedLink,
                pasteLink: { text in
                    if !handoff.send(text) { store.message = "The clipboard doesn’t contain a supported link." }
                }
            )
            .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }.tag(AppTab.downloads)
            LibraryView(store: store)
                .tabItem { Label("Library", systemImage: "play.rectangle.on.rectangle") }.tag(AppTab.library)
            SettingsView(store: store)
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppTab.settings)
        }
        .wrathMinimizeTabs()
        .wrathSoftScrollEdges()
        .sheet(
            item: Binding(get: { presentation.sheet }, set: { if $0 == nil { presentation.dismiss() } }),
            onDismiss: sheetDismissed
        ) { sheet in
            switch sheet {
            case .addLink:
                AddLinkSheet(store: store, link: "") {
                    tab = .downloads
                    activeDownloadChanged(activeDownloadID)
                }
            case .prefilledLink(let shared):
                AddLinkSheet(store: store, link: shared.url.absoluteString, preset: shared.preset) {
                    tab = .downloads
                    activeDownloadChanged(activeDownloadID)
                }
            case .download(let id):
                if let item = progressItem, item.id == id {
                    DownloadProgressSheet(
                        item: item, cancel: { store.cancel(item) }, togglePause: { store.toggleDownloadPause(item) })
                }
            case .redditLogin:
                SocialLoginView(site: .reddit)
            }
        }
        .onChange(of: activeDownloadID, initial: true) { _, id in activeDownloadChanged(id) }
        .onOpenURL { _ = handoff.receive($0) }
        .onChange(of: phase, initial: true) { _, phase in
            if phase == .active { copiedLink.refresh() }
        }
        .overlay(alignment: .top) { ToastOverlay(message: $store.toast) }
        .onChange(of: handoff.pending, initial: true) { openHandedOffLink() }
        .onChange(of: lock.isEnabled) { _, enabled in
            if enabled { store.redactSystemProgress() }
        }
        .onChange(of: lock.isUnlocked) { _, unlocked in
            guard unlocked else { return }
            activeDownloadChanged(activeDownloadID)
            openHandedOffLink()
        }
        .alert(
            "Wrath",
            isPresented: Binding(
                get: {
                    lock.isUnlocked && store.message != nil && presentation.sheet == nil && !presentation.isDismissing
                },
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
                    presentation.present(.redditLogin)
                }
            }
            Button("OK") {
                store.message = nil
                store.failedSocialLink = nil
            }
        } message: {
            Text(store.message ?? "")
        }
    }

    private var activeDownloadID: UUID? { store.activeItem?.id }

    private func showProgress(_ id: UUID) {
        guard lock.isUnlocked else { return }
        guard let item = store.items.first(where: { $0.id == id && $0.job.state.isActive }) else { return }
        progressItem = item
        presentation.present(.download(id))
    }

    private func activeDownloadChanged(_ id: UUID?) {
        if let id { progressItem = store.items.first(where: { $0.id == id }) }
        if lock.isUnlocked || id == nil { presentation.downloadChanged(id) }
    }

    private func sheetDismissed() {
        let changed = reconnectRevision != nil && SocialAccessStore.shared.revision != reconnectRevision
        let link = reconnectURL
        reconnectURL = nil
        reconnectRevision = nil
        presentation.didDismiss()
        switch presentation.sheet {
        case .download: break
        default: progressItem = nil
        }
        if changed, let link, presentation.sheet == nil {
            store.failedSocialLink = nil
            presentLink(SharedLink(url: link))
        }
    }

    /// Opens a link from Shortcuts, the share sheet or the clipboard once Wrath is unlocked.
    private func openHandedOffLink() {
        guard lock.isUnlocked, let link = handoff.take() else { return }
        presentLink(link)
    }

    private func presentLink(_ link: SharedLink) {
        guard !store.isDownloadOccupied else {
            tab = .downloads
            store.message = DownloadStore.busyMessage
            return
        }
        tab = .downloads
        presentation.present(.prefilledLink(link))
    }
}

/// A brief confirmation at the top of the screen that hides itself.
private struct ToastOverlay: View {
    @Binding var message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { self.message = nil }
                }
                .accessibilityAddTraits(.isStaticText)
        }
    }
}
