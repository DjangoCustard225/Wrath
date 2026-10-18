import SwiftUI
import WrathCore

struct FileDetailsView: View {
    let item: JobItem
    @Bindable var store: DownloadStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var loading = false
    @State private var renaming = false
    @State private var previewing = false

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }
    private var container: String { store.fileURL(item)?.pathExtension.uppercased() ?? "—" }
    private var resolution: String {
        guard let info = item.job.savedMediaInfo, let width = info.width, let height = info.height else { return "—" }
        return "\(width) × \(height)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                DetailCardSection(title: "At a glance") {
                    LazyVGrid(columns: columns, spacing: 10) {
                        DetailMetricCard(
                            title: "Size", value: MediaLabels.bytes(item.job.bytes), symbol: "externaldrive")
                        DetailMetricCard(
                            title: "Duration", value: MediaLabels.duration(item.job.savedMediaInfo?.duration) ?? "—",
                            symbol: "clock")
                        DetailMetricCard(title: "Container", value: container, symbol: "doc")
                        if item.job.kind == .video {
                            DetailMetricCard(
                                title: "Resolution", value: resolution, symbol: "rectangle.expand.vertical")
                        } else {
                            DetailMetricCard(
                                title: "Audio codec",
                                value: item.job.savedMediaInfo?.audioCodec.map(MediaLabels.codec) ?? "—",
                                symbol: "waveform")
                        }
                    }
                }
                DetailCardSection(title: "File") {
                    VStack(spacing: 0) {
                        if let filename = item.job.filename {
                            DetailValueRow(title: "Name", value: filename, copyable: true)
                            Divider()
                        }
                        DetailValueRow(title: "Type", value: item.job.kind.rawValue.capitalized)
                        Divider()
                        DetailValueRow(
                            title: item.job.completed == nil ? "Added" : "Saved",
                            value: (item.job.completed ?? item.job.created).formatted(
                                date: .abbreviated, time: .shortened))
                    }.padding(.horizontal, 16).modifier(MediaCardStyle(padding: 0, cornerRadius: 18))
                }
                mediaDetails
                if let warning = item.job.warning {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Saved with changes", systemImage: "exclamationmark.triangle").font(
                            .subheadline.weight(.semibold)
                        ).foregroundStyle(.orange)
                        Text(warning).font(.subheadline).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).modifier(
                        MediaCardStyle(padding: 16, cornerRadius: 18))
                }
                DetailCardSection(title: "Source") {
                    VStack(spacing: 0) {
                        DetailValueRow(title: "Website", value: item.job.sourceURL.host ?? "Unknown")
                        Divider()
                        DetailValueRow(title: "Link", value: item.job.sourceURL.absoluteString, copyable: true)
                        Divider()
                        Link(destination: item.job.sourceURL) {
                            HStack {
                                Text("Open source")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }.font(.subheadline.weight(.medium)).padding(.vertical, 15).contentShape(Rectangle())
                        }
                    }.padding(.horizontal, 16).modifier(MediaCardStyle(padding: 0, cornerRadius: 18))
                }
            }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 32)
        }
        .wrathSoftScrollEdges()
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("File details").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Preview", systemImage: "play") { previewing = true }
                    if let url = store.fileURL(item) {
                        ShareLink(item: url) { Label("Share file", systemImage: "square.and.arrow.up") }
                    }
                    Button("Rename", systemImage: "pencil") { renaming = true }
                } label: {
                    Image(systemName: "ellipsis")
                }.disabled(store.libraryBusyIDs.contains(item.id)).accessibilityLabel("File actions")
            }
        }
        .task { await loadDetails() }
        .refreshable { await loadDetails() }
        .sheet(isPresented: $renaming) { RenameFileSheet(item: item, store: store) }
        .sheet(isPresented: $previewing) { if let url = store.fileURL(item) { FilePreview(url: url) } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: item.job.kind == .video ? "video" : "waveform")
                    .font(.title2).foregroundStyle(.orange).frame(width: 50, height: 50)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved to Library").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    Text(item.job.kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(item.job.title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true).textSelection(
                .enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).modifier(MediaCardStyle(padding: 20))
    }

    @ViewBuilder private var mediaDetails: some View {
        DetailCardSection(title: "Media") {
            if let info = item.job.savedMediaInfo {
                VStack(spacing: 0) {
                    if let video = info.videoCodec {
                        DetailValueRow(title: "Video codec", value: MediaLabels.codec(video))
                        Divider()
                    }
                    if let audio = info.audioCodec {
                        DetailValueRow(title: "Audio codec", value: MediaLabels.codec(audio))
                        Divider()
                    }
                    if info.subtitles.isEmpty {
                        DetailValueRow(title: "Subtitles", value: "None embedded")
                    } else {
                        ForEach(Array(info.subtitles.enumerated()), id: \.offset) { index, subtitle in
                            if index > 0 { Divider() }
                            DetailValueRow(
                                title: info.subtitles.count == 1 ? "Subtitles" : "Subtitle \(index + 1)",
                                value: subtitleLabel(subtitle))
                        }
                    }
                }.padding(.horizontal, 16).modifier(MediaCardStyle(padding: 0, cornerRadius: 18))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if loading {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Reading file details…").font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Additional media details are unavailable.").font(.subheadline).foregroundStyle(.secondary)
                        Button("Read details again", systemImage: "arrow.clockwise") { Task { await loadDetails() } }
                            .wrathGlassButton()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).modifier(
                    MediaCardStyle(padding: 16, cornerRadius: 18))
            }
        }
    }

    private func loadDetails() async {
        guard !loading else { return }
        loading = true
        await store.loadFileDetails(item)
        loading = false
    }
    private func subtitleLabel(_ info: SavedSubtitleInfo) -> String {
        if let name = info.name, !name.isEmpty, name != "SubtitleHandler" { return name }
        if let language = info.language { return Locale.current.localizedString(forLanguageCode: language) ?? language }
        return "Unspecified language"
    }
}

struct RenameFileSheet: View {
    let item: JobItem
    @Bindable var store: DownloadStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("File name", text: $name).focused($focused)
                        .textInputAutocapitalization(.sentences).autocorrectionDisabled().submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    Text("The file extension stays the same.")
                }
                if let error { Section { Text(error).font(.subheadline).foregroundStyle(.orange) } }
                if saving {
                    Section {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Renaming file…").foregroundStyle(.secondary)
                        }
                    }
                }
            }.navigationTitle("Rename file").navigationBarTitleDisplayMode(.inline)
                .wrathHideBottomEdge(focused)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save).disabled(
                            saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }.presentationDetents([.medium, .large]).interactiveDismissDisabled(saving)
            .onAppear {
                name = (item.job.filename as NSString?)?.deletingPathExtension ?? item.job.title
                focused = true
            }
    }
    private func save() {
        guard !saving else { return }
        saving = true
        error = nil
        Task {
            if let failure = await store.rename(item, stem: name) {
                error = failure
                saving = false
            } else {
                dismiss()
            }
        }
    }
}
