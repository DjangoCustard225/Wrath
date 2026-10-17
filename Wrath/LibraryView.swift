import SwiftUI
import WrathCore

private enum LibraryLayout: String { case list, grid }
private enum LibrarySheet: Identifiable {
    case preview(URL)
    case rename(JobItem)
    var id: String {
        switch self {
        case .preview(let url): "preview-" + url.path
        case .rename(let item): "rename-" + item.id.uuidString
        }
    }
}

struct LibraryView: View {
    @Bindable var store: DownloadStore
    @AppStorage("librarySort") private var sort: LibrarySort = .newest
    @AppStorage("libraryLayout") private var layout: LibraryLayout = .list
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sheet: LibrarySheet?
    @State private var detail: JobItem?
    @State private var deleting: JobItem?
    @State private var busyDeleting = false
    private var ordered: [JobItem] { store.library.sorted { sort.precedes($0.job, $1.job) } }
    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 160, maximum: 280), spacing: 14, alignment: .top)]
    }
    var body: some View {
        NavigationStack {
            Group {
                if store.library.isEmpty {
                    ContentUnavailableView(
                        "No saved files", systemImage: "play.rectangle",
                        description: Text("Downloaded video and audio will appear here.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                } else if layout == .list {
                    LibraryListScrollView {
                        ForEach(ordered) { item in
                            Button {
                                preview(item)
                            } label: {
                                LibraryCard(item: item, prominent: true)
                            }.buttonStyle(.plain)
                                .disabled(busyDeleting || store.libraryBusyIDs.contains(item.id))
                                .contextMenu { fileActions(for: item) }
                                .modifier(LibraryCardScrollEffect())
                        }
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(ordered) { item in
                                Button {
                                    preview(item)
                                } label: {
                                    LibraryCard(item: item)
                                }
                                .buttonStyle(.plain)
                                .disabled(busyDeleting || store.libraryBusyIDs.contains(item.id))
                                .contextMenu { fileActions(for: item) }
                            }
                        }.padding(.horizontal, 20).padding(.vertical, 16)
                    }.background(Color(uiColor: .systemGroupedBackground))
                }
            }.navigationTitle("Library")
                .navigationBarTitleDisplayMode(.large)
                .navigationDestination(isPresented: Binding(get: { detail != nil }, set: { if !$0 { detail = nil } })) {
                    if let detail { FileDetailsView(item: detail, store: store) }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Section("Sort by") {
                                Picker("Sort by", selection: $sort) {
                                    ForEach(LibrarySort.allCases, id: \.self) { Text($0.label).tag($0) }
                                }.pickerStyle(.inline)
                            }
                            Section("View") {
                                Picker("View", selection: $layout) {
                                    Label("Grid", systemImage: "square.grid.2x2").tag(LibraryLayout.grid)
                                    Label("List", systemImage: "list.bullet").tag(LibraryLayout.list)
                                }.pickerStyle(.inline)
                            }
                        } label: {
                            Label("Sort and view", systemImage: "arrow.up.arrow.down")
                        }
                    }
                }
        }.sheet(item: $sheet) { presented in
            switch presented {
            case .preview(let url): FilePreview(url: url)
            case .rename(let item): RenameFileSheet(item: item, store: store)
            }
        }
        .confirmationDialog(
            deletionTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete file", role: .destructive) {
                guard let item = deleting else { return }
                deleting = nil
                busyDeleting = true
                Task {
                    _ = await store.deleteFiles([item.id])
                    busyDeleting = false
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
    }
    private var deletionTitle: String {
        "Delete this file (\(MediaLabels.bytes(deleting?.job.bytes ?? 0))) from Wrath?"
    }
    private func preview(_ item: JobItem) {
        if let url = store.fileURL(item) { sheet = .preview(url) }
    }
    @ViewBuilder private func fileActions(for item: JobItem) -> some View {
        Button("File details", systemImage: "info.circle") { detail = item }
        Button("Rename", systemImage: "pencil") { sheet = .rename(item) }
        if let url = store.fileURL(item) {
            ShareLink(item: url) { Label("Share file", systemImage: "square.and.arrow.up") }
        }
        Button("Delete file", systemImage: "trash", role: .destructive) { deleting = item }
    }
}

struct LibraryCard: View {
    var item: JobItem
    var prominent = false
    var body: some View {
        VStack(alignment: .leading, spacing: prominent ? 12 : 10) {
            MediaArtwork(url: item.job.thumbnail, kind: item.job.kind, maxPixelSize: prominent ? 1200 : 512)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.job.title).font(prominent ? .headline : .subheadline.weight(.semibold)).lineLimit(
                    prominent ? 3 : 2
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(item.job.kind.rawValue.capitalized) · \(MediaLabels.bytes(item.job.bytes))")
                    .font(.caption).foregroundStyle(.secondary)
                if let warning = item.job.warning {
                    Label(DownloadWarnings.summary(warning), systemImage: "exclamationmark.triangle").font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }.foregroundStyle(.primary)
            .modifier(MediaCardStyle())
            .accessibilityElement(children: .combine)
    }
}
