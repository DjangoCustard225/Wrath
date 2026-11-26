import SwiftUI
import WrathCore

private enum LibrarySheet: Identifiable {
    case preview(URL)
    case rename(JobItem)
    case share([URL])
    var id: String {
        switch self {
        case .preview(let url): "preview-" + url.path
        case .rename(let item): "rename-" + item.id.uuidString
        case .share(let urls): "share-" + urls.map(\.path).joined(separator: "|")
        }
    }
}

struct LibraryView: View {
    @Bindable var store: DownloadStore
    @AppStorage(PreferenceKey.librarySort) private var sort: LibrarySort = .newest
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sheet: LibrarySheet?
    @State private var detail: JobItem?
    @State private var deleting: [JobItem] = []
    @State private var busyDeleting = false
    @State private var query = ""
    @State private var selection: Set<UUID> = []
    @State private var editMode: EditMode = .inactive

    private var selecting: Bool { editMode.isEditing }
    private var ordered: [JobItem] {
        store.library.filter { LibrarySearch.matches($0.job, query: query) }
            .sorted { sort.precedes($0.job, $1.job) }
    }
    private var selectedItems: [JobItem] { ordered.filter { selection.contains($0.id) } }
    private var deletionTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
    }

    var body: some View {
        let library = ordered
        NavigationStack {
            ZStack {
                LibraryListScrollView(selection: $selection) {
                    ForEach(library) { item in
                        row(for: item)
                            .tag(item.id)
                            .disabled(busyDeleting || store.libraryBusyIDs.contains(item.id))
                            .contextMenu { if !selecting { fileActions(for: item) } }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Delete", systemImage: "trash") { deleting = [item] }.tint(.red)
                                Button("Share", systemImage: "square.and.arrow.up") {
                                    sheet = .share(store.savedURLs(item))
                                }.tint(.blue)
                            }
                            .swipeActions(edge: .leading) {
                                if PhotoLibraryCompatibility.canSave(item.job) {
                                    Button("Save to Photos", systemImage: "photo.badge.plus") {
                                        Task { await store.saveToPhotos([item]) }
                                    }.tint(.orange)
                                }
                            }
                            .modifier(LibraryCardScrollEffect())
                            .transition(.asymmetric(insertion: .opacity, removal: deletionTransition))
                    }
                }
                .environment(\.editMode, $editMode)
                if library.isEmpty {
                    Group {
                        if query.isEmpty {
                            ContentUnavailableView(
                                "No saved files", systemImage: "play.rectangle",
                                description: Text("Downloaded videos, audio, and photo galleries will appear here.")
                            )
                        } else {
                            ContentUnavailableView.search(text: query)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: library.map(\.id))
            .navigationTitle(selecting ? selectionTitle : "Library")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: "Title, channel, or site")
            .navigationDestination(isPresented: Binding(get: { detail != nil }, set: { if !$0 { detail = nil } })) {
                if let detail {
                    if detail.job.kind == .images {
                        GalleryDetailsView(item: detail, store: store)
                    } else {
                        FileDetailsView(item: detail, store: store)
                    }
                }
            }
            .toolbar { toolbar(hasItems: !library.isEmpty) }
            .toolbar(selecting ? .hidden : .automatic, for: .tabBar)
            .onChange(of: store.library.map(\.id)) { _, ids in selection.formIntersection(ids) }
        }.sheet(item: $sheet) { presented in
            switch presented {
            case .preview(let url): FilePreview(url: url)
            case .rename(let item): RenameFileSheet(item: item, store: store)
            case .share(let urls): ActivityShareSheet(urls: urls).presentationDetents([.medium, .large])
            }
        }
        .confirmationDialog(
            deletionTitle, isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
            titleVisibility: .visible
        ) {
            Button(deleting.count == 1 ? "Delete file" : "Delete \(deleting.count) files", role: .destructive) {
                let ids = Set(deleting.map(\.id))
                deleting = []
                busyDeleting = true
                Task {
                    let removed = await store.deleteFiles(ids)
                    selection.subtract(removed)
                    if selection.isEmpty { editMode = .inactive }
                    busyDeleting = false
                }
            }
            Button("Cancel", role: .cancel) { deleting = [] }
        }
    }

    @ViewBuilder private func row(for item: JobItem) -> some View {
        if selecting {
            LibraryCard(item: item)
        } else {
            Button {
                preview(item)
            } label: {
                LibraryCard(item: item)
            }.buttonStyle(.plain)
        }
    }

    @ToolbarContentBuilder private func toolbar(hasItems: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if hasItems || selecting {
                Button(selecting ? "Done" : "Select") {
                    withAnimation {
                        editMode = selecting ? .inactive : .active
                        selection = []
                    }
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section("Sort by") {
                    Picker("Sort by", selection: $sort) {
                        ForEach(LibrarySort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.inline)
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
        if selecting {
            ToolbarItemGroup(placement: .bottomBar) {
                let items = selectedItems
                Button("Share", systemImage: "square.and.arrow.up") {
                    sheet = .share(items.flatMap(store.savedURLs))
                }.disabled(items.isEmpty)
                Spacer()
                Button("Save to Photos", systemImage: "photo.badge.plus") {
                    Task { await store.saveToPhotos(items) }
                }.disabled(!items.contains { PhotoLibraryCompatibility.canSave($0.job) })
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = items }
                    .disabled(items.isEmpty).tint(.red)
            }
        }
    }

    private var selectionTitle: String {
        selection.isEmpty ? "Select items" : "\(selection.count) selected"
    }

    private var deletionTitle: String {
        let bytes = deleting.reduce(Int64(0)) { $0 + $1.job.bytes }
        return deleting.count == 1
            ? "Delete this file (\(MediaLabels.bytes(bytes))) from Wrath?"
            : "Delete \(deleting.count) files (\(MediaLabels.bytes(bytes))) from Wrath?"
    }

    private func preview(_ item: JobItem) {
        if item.job.kind == .images { detail = item } else if let url = store.fileURL(item) { sheet = .preview(url) }
    }

    @ViewBuilder private func fileActions(for item: JobItem) -> some View {
        Button("File details", systemImage: "info.circle") { detail = item }
        Button("Rename", systemImage: "pencil") { sheet = .rename(item) }
        if item.job.kind != .images, let url = store.fileURL(item) {
            ShareLink(item: url) { Label("Share file", systemImage: "square.and.arrow.up") }
        }
        if PhotoLibraryCompatibility.canSave(item.job) {
            Button("Save to Photos", systemImage: "photo.badge.plus") { Task { await store.saveToPhotos([item]) } }
        }
        Button("Delete file", systemImage: "trash", role: .destructive) { deleting = [item] }
    }
}

struct LibraryCard: View {
    var item: JobItem
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MediaArtwork(url: item.libraryArtwork, kind: item.job.kind, maxPixelSize: 1200)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.job.title).font(.headline).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(
                    item.job.kind == .images
                        ? "\(item.job.galleryFiles?.count ?? 0) photos · \(MediaLabels.bytes(item.job.bytes))"
                        : "\(item.job.kind.rawValue.capitalized) · \(MediaLabels.bytes(item.job.bytes))"
                )
                .font(.caption).foregroundStyle(.secondary)
                if let warning = DownloadWarnings.visible(item.job.warning, for: item.job.kind) {
                    Label(DownloadWarnings.summary(warning), systemImage: "exclamationmark.triangle").font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }.foregroundStyle(.primary)
            .modifier(MediaCardStyle())
            .accessibilityElement(children: .combine)
    }
}
