import SwiftUI
import WrathCore

// Layout adapted from Quby’s AddTorrentView.
// Copyright (c) 2026 Ammar Haseeb. MIT license: Resources/Licenses/Quby.txt.
struct AddLinkSheet: View {
    @Bindable var store: DownloadStore
    @State var link: String
    @State private var inspector = LinkInspector()
    @State private var socialAccess = SocialAccessStore.shared
    @State private var keyboardVisible = false
    @State private var showingOptions = false
    @State private var loginSite: SocialPlatform?
    let added: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    private var validURL: URL? { LinkInput.parse(link) }
    private var socialSite: SocialPlatform? {
        validURL.flatMap(SocialPlatform.forURL).flatMap { $0.supportsCookies ? $0 : nil }
    }
    private var isYouTube: Bool { validURL.flatMap(YouTubeLink.videoID) != nil }
    private var availability: CodecAvailability? { inspector.sourceURL == validURL ? inspector.availability : nil }
    private var invalidOptions: Bool {
        guard let availability else { return false }
        return !availability.supports(kind: store.kind, quality: store.quality, options: store.options)
            || (isYouTube && store.options.sponsorMode != .off && store.options.sponsorCategories.isEmpty)
    }
    private var sourceReady: Bool { validURL != nil && availability?.mediaKinds.isEmpty == false }
    private var canDownload: Bool { sourceReady && !invalidOptions && store.canAddDownload }
    var body: some View {
        NavigationStack {
            page {
                sourceCard
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
                if sourceReady { nextButton }
            }
            .wrathHideBottomEdge(focused || keyboardVisible)
            .navigationTitle("Add a link").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationDestination(isPresented: $showingOptions) { downloadPage }
        }
        // The sheet owns inspection so navigation never cancels or restarts it.
        .task(
            id: LinkInspectionRequest(
                url: validURL, revision: inspector.revision,
                accessRevision: socialSite != nil ? socialAccess.revision : nil)
        ) {
            await inspector.inspect(
                validURL,
                context: socialSite != nil ? socialAccess.revision : nil)
        }
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
        .onChange(of: inspector.availability) { _, _ in
            resolveOptions()
            continueToOptions()
        }
        .onChange(of: validURL) { _, _ in showingOptions = false }
        .onChange(of: store.kind) { _, _ in resolveOptions() }
        .onChange(of: store.quality) { _, _ in resolveOptions() }
        .onChange(of: store.options.videoCodec) { _, _ in resolveOptions() }
    }
    private func page<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24, content: content)
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .wrathSoftScrollEdges()
        .scrollDismissesKeyboard(.interactively)
    }
    private var downloadPage: some View {
        page {
            if let availability, !availability.mediaKinds.isEmpty {
                SourcePreview(availability: availability, kind: store.kind)
                    .modifier(MediaCardStyle(padding: 12))
                formatCard(availability)
                optionsCard(availability)
            }
        }
        .wrathBottomBar { downloadButton }
        .wrathHideBottomEdge(focused || keyboardVisible)
        .navigationTitle("Download options").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
    }
    private var nextButton: some View {
        Button(action: continueToOptions) {
            Label("Next", systemImage: "arrow.right")
                .font(.headline).frame(maxWidth: .infinity, minHeight: 28)
        }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
            .frame(maxWidth: 600).frame(maxWidth: .infinity)
            .padding(.horizontal, 18).padding(.vertical, 12)
    }
    private func continueToOptions() {
        guard sourceReady else { return }
        focused = false
        showingOptions = true
    }
    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "link").font(.title2).foregroundStyle(.orange)
                    .frame(width: 50, height: 50)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Media link").font(.headline)
                    Text(validURL?.host() ?? "Video or audio from a link")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Divider()
            TextField("Paste a video or audio link", text: $link, axis: .vertical)
                .font(.subheadline).lineLimit(1...5)
                .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never)
                .autocorrectionDisabled().focused($focused).submitLabel(.next).onSubmit(continueToOptions)
                .accessibilityLabel("Media link")
            inputStatus.font(.caption)
            if let site = socialSite {
                Divider()
                Text(
                    "Copy the full Reddit post URL from your browser’s address bar, not the Reddit app. Use a link containing /comments/."
                )
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("reddit-browser-link-note")
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(site.name + " access").font(.subheadline.weight(.medium))
                        Text(
                            socialAccess.cookieCounts[site, default: 0] > 0
                                ? "Cookies saved" : "Sign in if this link requires an account"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(socialAccess.cookieCounts[site, default: 0] > 0 ? "Reconnect" : "Connect") {
                        focused = false
                        loginSite = site
                    }.buttonStyle(.bordered)
                }
            }
        }.modifier(MediaCardStyle(padding: 20))
    }
    private var clearLinkButton: some View {
        Button {
            link = ""
            focused = true
        } label: {
            Text("CLEAR LINK")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .tracking(1.8).frame(maxWidth: .infinity, minHeight: 28)
        }
        .wrathGlassButton(clear: true).buttonBorderShape(.capsule).controlSize(.large)
        .foregroundStyle(.primary).accessibilityLabel("Clear link")
    }
    @ViewBuilder private var inputStatus: some View {
        if sourceReady {
            Label("Link checked", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validURL == nil {
            Label("Enter a valid link", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        }
    }
    private func formatCard(_ availability: CodecAvailability) -> some View {
        DetailCardSection(title: "Save as") {
            VStack(spacing: 16) {
                Picker("Save as", selection: $store.kind) {
                    ForEach(availability.mediaKinds, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.pickerStyle(.segmented)
                if store.kind == .video {
                    Divider()
                    LabeledContent("Quality") {
                        Picker("Quality", selection: $store.quality) {
                            ForEach(availability.qualities, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden().pickerStyle(.menu)
                    }
                }
                Divider()
                SizeEstimateRow(
                    availability: availability, kind: store.kind, quality: store.quality, options: store.options)
            }.font(.subheadline).modifier(MediaCardStyle(padding: 16))
        }
    }
    private func optionsCard(_ availability: CodecAvailability) -> some View {
        DetailCardSection(title: "Options") {
            SourceOptions(
                availability: availability, kind: store.kind, quality: store.quality,
                isYouTube: isYouTube, options: $store.options, cardLayout: true
            )
            .font(.subheadline).modifier(MediaCardStyle(padding: 16))
        }
    }
    private var downloadButton: some View {
        Button(action: add) {
            Label("Download", systemImage: "arrow.down.circle")
                .font(.headline).frame(maxWidth: .infinity, minHeight: 28)
        }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
            .disabled(!canDownload)
            .frame(maxWidth: 600).frame(maxWidth: .infinity)
            .padding(.horizontal, 18).padding(.vertical, 12)
    }
    private func resolveOptions() {
        guard let availability, let firstKind = availability.mediaKinds.first else { return }
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
