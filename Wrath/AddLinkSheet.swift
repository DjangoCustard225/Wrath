import SwiftUI
import WrathCore

// Layout adapted from Quby’s AddTorrentView.
// Copyright (c) 2026 Ammar Haseeb. MIT license: Resources/Licenses/Quby.txt.
/// Takes a link, checks what it offers, then collects download options on a second page.
struct AddLinkSheet: View {
    @Bindable var store: DownloadStore
    private let initialLink: String
    private let preset: SharePreset
    @State private var presetApplied = false
    @State private var editedLink: String?
    @State private var inspector = LinkInspector()
    @State private var socialAccess = SocialAccessStore.shared
    @State private var keyboardVisible = false
    @State private var showingOptions = false
    @State private var loginSite: SocialPlatform?
    let added: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(store: DownloadStore, link: String, preset: SharePreset = .none, added: @escaping () -> Void) {
        self.store = store
        initialLink = link
        self.preset = preset
        self.added = added
    }

    private var link: String {
        get { editedLink ?? initialLink }
        nonmutating set { editedLink = newValue }
    }

    private var validURL: URL? { LinkInput.parse(link) }
    private var socialSite: SocialPlatform? {
        validURL.flatMap(SocialPlatform.forURL).flatMap { $0.supportsCookies ? $0 : nil }
    }
    private var isYouTube: Bool { validURL.flatMap(YouTubeLink.videoID) != nil }
    private var availability: CodecAvailability? { inspector.sourceURL == validURL ? inspector.availability : nil }
    private var invalidOptions: Bool {
        guard let availability else { return false }
        if availability.gallery != nil { return false }
        return !availability.supports(kind: store.kind, quality: store.quality, options: store.options)
            || (isYouTube && store.options.sponsorMode != .off && store.options.sponsorCategories.isEmpty)
    }
    private var sourceReady: Bool { validURL != nil && availability?.mediaKinds.isEmpty == false }
    private var canDownload: Bool { sourceReady && !invalidOptions && store.canAddDownload }

    var body: some View {
        NavigationStack {
            AddLinkPage {
                LinkSourceCard(
                    link: Binding(get: { link }, set: { link = $0 }), url: validURL, checked: sourceReady,
                    socialSite: socialSite, focus: $focused, submit: continueToOptions
                ) { site in
                    focused = false
                    loginSite = site
                }
                VStack(spacing: 12) {
                    CohesivePasteButton { value in
                        link = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        focused = false
                    }
                    if !link.isEmpty { clearLinkButton }
                }
                if validURL != nil && !sourceReady {
                    SourceInspectionStatus(inspector: inspector, url: validURL)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(MediaCardStyle(padding: 20))
                }
            }
            .wrathBottomBar {
                if sourceReady {
                    BottomBarActionButton(title: "Next", systemImage: "arrow.right", action: continueToOptions)
                }
            }
            .wrathHideBottomEdge(focused || keyboardVisible)
            .navigationTitle("Add a link").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationDestination(isPresented: $showingOptions) { downloadPage }
        }
        // The sheet owns inspection so navigation never cancels or restarts it.
        .task(id: LinkInspectionRequest(url: validURL, revision: inspector.revision, accessRevision: accessRevision)) {
            applyPreset()
            await inspector.inspect(validURL, context: accessRevision)
            guard !Task.isCancelled else { return }
            resolveOptions()
            if startsImmediately {
                add()
            } else {
                continueToOptions()
            }
        }
        .sensoryFeedback(.success, trigger: sourceReady) { _, ready in ready }
        .sheet(item: $loginSite) { site in
            SocialLoginView(site: site)
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardVisible = false
        }
        .onChange(of: validURL) { _, _ in showingOptions = false }
        .onChange(of: store.kind) { _, _ in resolveOptions() }
        .onChange(of: store.quality) { _, _ in resolveOptions() }
        .onChange(of: store.options.videoCodec) { _, _ in resolveOptions() }
    }

    /// Saved sign-ins change what a social link can return, so they are part of the inspection key.
    private var accessRevision: UUID? { socialSite != nil ? socialAccess.revision : nil }

    private var downloadPage: some View {
        AddLinkPage {
            if let availability, !availability.mediaKinds.isEmpty {
                SourcePreview(availability: availability, kind: availability.gallery == nil ? store.kind : .images)
                    .modifier(MediaCardStyle(padding: 12))
                if let gallery = availability.gallery {
                    GalleryCard(gallery: gallery)
                } else {
                    FormatCard(
                        availability: availability, kind: $store.kind, quality: $store.quality, options: store.options)
                    DetailCardSection(title: "Options") {
                        SourceOptions(
                            availability: availability, kind: store.kind, quality: store.quality,
                            isYouTube: isYouTube, options: $store.options, cardLayout: true
                        )
                        .font(.subheadline).modifier(MediaCardStyle(padding: 16))
                    }
                }
            }
        }
        .wrathBottomBar {
            BottomBarActionButton(
                title: "Download", systemImage: "arrow.down.circle", enabled: canDownload, action: add)
        }
        .wrathHideBottomEdge(focused || keyboardVisible)
        .navigationTitle("Download options").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
    }

    /// Applies the share sheet's format and quality once, before the link is checked.
    private func applyPreset() {
        guard !presetApplied else { return }
        presetApplied = true
        if let kind = preset.kind { store.kind = kind }
        if let quality = preset.quality { store.quality = quality }
    }

    /// "Download Now" from the share sheet skips the options page when the link and choices are valid.
    private var startsImmediately: Bool {
        preset.startNow && validURL?.absoluteString == initialLink && editedLink == nil && canDownload
    }

    private func continueToOptions() {
        guard sourceReady else { return }
        focused = false
        showingOptions = true
    }

    private var clearLinkButton: some View {
        Button {
            link = ""
            focused = true
        } label: {
            CapsuleButtonTitle(title: "Clear link")
        }
        .wrathGlassButton(clear: true).buttonBorderShape(.capsule).controlSize(.large)
        .foregroundStyle(.primary)
    }

    private func resolveOptions() {
        guard let availability, let firstKind = availability.mediaKinds.first else { return }
        guard availability.gallery == nil else { return }
        let kind = availability.mediaKinds.contains(store.kind) ? store.kind : firstKind
        let quality = kind == .video ? availability.resolvingQuality(store.quality) : store.quality
        if store.kind != kind { store.kind = kind }
        if store.quality != quality { store.quality = quality }
        let resolved = availability.resolving(store.options, kind: kind, quality: quality)
        if resolved != store.options { store.options = resolved }
    }

    private func add() {
        guard canDownload, let url = validURL else { return }
        guard store.add(url, availability: availability) else { return }
        added()
        dismiss()
    }
}
