import SwiftUI

/// The 1DM+-style grab list: everything the scanner found on the page,
/// grouped by kind, with sizes and checkboxes. Downloading queues the
/// selection through DownloadStore, exactly like pasted links.
struct GrabListView: View {
    @Bindable var grabber: MediaGrabber
    @Bindable var store: DownloadStore
    /// Called once the selection has been queued, so the browser can close.
    let onDownload: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if grabber.blobCount > 0 {
                    Section {
                        Label(blobNote, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                    }
                }
                if grabber.items.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No media found",
                            systemImage: "magnifyingglass",
                            description: Text(
                                "Let the page finish loading, start the video or audio playing, then scan again.")
                        )
                    }
                }
                ForEach(GrabKind.allCases) { kind in
                    let group = grabber.items(of: kind)
                    if !group.isEmpty {
                        Section {
                            ForEach(group) { item in
                                row(item)
                            }
                        } header: {
                            Text(kind.title)
                        }
                    }
                }
            }
            .navigationTitle("Grab media").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Rescan") { grabber.rescan() }
                }
            }
            .wrathBottomBar { downloadBar }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
    }

    private var blobNote: String {
        grabber.blobCount == 1
            ? "1 stream on this page plays through a blob: URL, which has no file address to download. "
                + "Paste the page link with Add Link instead — the extractor can fetch those."
            : "\(grabber.blobCount) streams on this page play through blob: URLs, which have no file address "
                + "to download. Paste the page link with Add Link instead — the extractor can fetch those."
    }

    private func row(_ item: GrabbedMedia) -> some View {
        Button {
            grabber.toggle(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: grabber.isSelected(item) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(grabber.isSelected(item) ? Color.orange : Color.secondary)
                Image(systemName: item.kind.systemImage)
                    .foregroundStyle(.orange)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.filename)
                        .font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(sizeText(item))
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.filename), \(item.kind.title)")
        .accessibilityValue(
            "\(grabber.isSelected(item) ? "Selected" : "Not selected"), \(sizeText(item))")
    }

    private func sizeText(_ item: GrabbedMedia) -> String {
        if let size = item.size { return MediaLabels.bytes(size) }
        return item.sizeResolved ? "—" : "…"
    }

    private var downloadBar: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Select all") { grabber.selectAll() }
                Button("None") { grabber.selectNone() }
                Spacer()
                Text(totalText).font(.caption).foregroundStyle(.secondary)
            }
            Button(action: downloadSelected) {
                Label(downloadLabel, systemImage: "arrow.down.circle")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
            .disabled(grabber.selectedItems.isEmpty)
        }
        .frame(maxWidth: 600).frame(maxWidth: .infinity)
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var totalText: String {
        let count = grabber.selectedItems.count
        guard count > 0 else { return "Nothing selected" }
        let bytes = MediaLabels.bytes(grabber.selectedBytes)
        return grabber.selectedBytesKnown
            ? "\(count) selected · \(bytes)" : "\(count) selected · \(bytes) known"
    }

    private var downloadLabel: String {
        let count = grabber.selectedItems.count
        return count == 1 ? "Download 1 file" : "Download \(count) files"
    }

    private func downloadSelected() {
        let chosen = grabber.selectedItems
        guard !chosen.isEmpty else { return }
        GrabDownloadQueue.shared.enqueue(chosen, store: store)
        dismiss()
        onDownload()
    }
}
