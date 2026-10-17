import SwiftUI
import WrathCore

struct DownloadDetail: View {
    var item: JobItem
    @Bindable var store: DownloadStore
    @State private var inspector = LinkInspector()
    private var editable: Bool { [.queued, .failed, .cancelled].contains(item.job.state) }
    private var inspectionURL: URL? { editable ? item.job.sourceURL : nil }
    private var availability: CodecAvailability? {
        editable
            ? (inspector.sourceURL == item.job.sourceURL ? inspector.availability : nil) : item.job.codecAvailability
    }
    private var options: Binding<DownloadOptions> {
        Binding(get: { item.job.effectiveOptions }, set: { store.updateOptions(item, options: $0) })
    }
    private var kind: Binding<MediaKind> {
        Binding(get: { item.job.kind }, set: { store.updateSelection(item, kind: $0, quality: item.job.quality) })
    }
    private var quality: Binding<Quality> {
        Binding(get: { item.job.quality }, set: { store.updateSelection(item, kind: item.job.kind, quality: $0) })
    }
    private var isYouTube: Bool { YouTubeLink.videoID(item.job.sourceURL) != nil }
    private var canRetry: Bool {
        availability?.supports(kind: item.job.kind, quality: item.job.quality, options: item.job.effectiveOptions)
            == true
            && (!isYouTube || item.job.effectiveOptions.sponsorMode == .off
                || !item.job.effectiveOptions.sponsorCategories.isEmpty)
    }
    var body: some View {
        List {
            Section {
                if item.job.state.isActive { ActiveDownloadCard(item: item) } else { DownloadRow(item: item) }
            }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            if let error = item.job.error {
                Section("Couldn’t finish") {
                    Text(error).font(.subheadline).textSelection(.enabled)
                    Button("Copy details", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string =
                            "Wrath \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")\n\(item.job.sourceURL.absoluteString)\n\(error)"
                    }
                }
            }
            if item.job.state == .completed, let warning = item.job.warning {
                Section("Saved with changes") { Text(warning).font(.subheadline).textSelection(.enabled) }
            }
            Section {
                if editable, let availability, !availability.mediaKinds.isEmpty {
                    Picker("Save as", selection: kind) {
                        ForEach(availability.mediaKinds, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    if item.job.kind == .video {
                        Picker("Quality", selection: quality) {
                            ForEach(availability.qualities, id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                    SizeEstimateRow(
                        availability: availability, kind: item.job.kind, quality: item.job.quality,
                        options: item.job.effectiveOptions)
                } else if editable {
                    SourceInspectionStatus(inspector: inspector, url: inspectionURL)
                } else {
                    LabeledContent("Format", value: item.job.kind.rawValue.capitalized)
                    if item.job.kind == .video { LabeledContent("Quality", value: item.job.quality.label) }
                }
                Link(destination: item.job.sourceURL) { Label("Open source", systemImage: "arrow.up.right") }
            }
            if let availability, !availability.mediaKinds.isEmpty {
                if editable {
                    Section("Download options") {
                        SourceOptions(
                            availability: availability, kind: item.job.kind, quality: item.job.quality,
                            isYouTube: isYouTube, options: options)
                    }
                } else {
                    Section {
                        DisclosureGroup("Download options") {
                            SourceOptions(
                                availability: availability, kind: item.job.kind, quality: item.job.quality,
                                isYouTube: isYouTube, options: options
                            ).disabled(true)
                        }
                    }
                }
            }
            if isYouTube, item.job.effectiveOptions.sponsorMode != .off, let found = item.job.sponsorSegmentsFound {
                Section {
                    Text(found == 0 ? "No matching SponsorBlock segments." : "\(found) SponsorBlock segments matched.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                if [.failed, .cancelled].contains(item.job.state) {
                    Button("Try again", systemImage: "arrow.clockwise") { store.retry(item) }.disabled(!canRetry)
                } else if item.job.state.isActive || item.job.state == .queued {
                    Button("Cancel download", systemImage: "xmark", role: .destructive) { store.cancel(item) }
                } else if item.job.state == .completed {
                    NavigationLink("File details") { FileDetailsView(item: item, store: store) }
                }
            }
        }.navigationTitle("Download").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .task(id: LinkInspectionRequest(url: inspectionURL, revision: inspector.revision)) {
                await inspector.inspect(inspectionURL)
            }
            .onChange(of: inspector.availability) { _, availability in
                if let availability { store.updateAvailability(item, availability: availability) }
            }
    }
}
