import SwiftUI
import WrathCore

struct DownloadsView: View {
    @Bindable var store: DownloadStore
    @Binding var adding: Bool
    @State private var detail: JobItem?
    @State private var showingRecent = false
    private var itemIDs: Set<UUID> { Set(store.items.map(\.id)) }
    private var hasCurrentDownloads: Bool { store.activeCount > 0 }
    private var active: [JobItem] { store.queue.filter { $0.job.state.isActive } }
    private var waiting: [JobItem] { store.queue.filter { $0.job.state == .queued } }
    private var recent: [JobItem] {
        store.queue.filter { !$0.job.state.isActive && $0.job.state != .queued }.reversed()
    }
    private var recentIDs: Set<UUID> { Set(recent.map(\.id)) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.queue.isEmpty {
                    LiquidPlusButton(diameter: 104) { adding = true }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if hasCurrentDownloads {
                                DownloadQueueHeader(store: store, active: active.count, waiting: waiting.count)
                            } else {
                                LiquidPlusButton(diameter: 104) { adding = true }
                                    .frame(maxWidth: .infinity)
                                    .containerRelativeFrame(.vertical) { height, _ in max(240, height * 0.65) }
                            }
                            ForEach(active) { item in
                                ActiveDownloadCard(
                                    item: item, openDetails: { detail = item }, cancel: { store.cancel(item) })
                            }
                            if !waiting.isEmpty {
                                QueueSectionHeader(title: "Up next", count: waiting.count)
                                ForEach(Array(waiting.enumerated()), id: \.element.id) { index, item in
                                    QueueItemCard(
                                        item: item, position: index + 1, paused: store.isPaused,
                                        open: { detail = item }, remove: { store.cancel(item) })
                                }
                            }
                            if !recent.isEmpty {
                                DisclosureGroup(isExpanded: $showingRecent) {
                                    LazyVStack(spacing: 10) {
                                        ForEach(recent) { item in
                                            QueueItemCard(
                                                item: item, open: { detail = item }, remove: { store.remove(item) })
                                        }
                                    }.padding(.top, 10)
                                } label: {
                                    QueueSectionHeader(title: "Recent", count: recent.count)
                                }.tint(.secondary).padding(.top, 6)
                            }
                        }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 24)
                    }.scrollEdgeEffectStyle(.soft, for: .all)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Wrath")
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                if hasCurrentDownloads {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Add a link", systemImage: "plus") { adding = true }
                            .accessibilityHint("Choose a link to download video or audio")
                    }
                }
            }
            .navigationDestination(isPresented: Binding(get: { detail != nil }, set: { if !$0 { detail = nil } })) {
                if let detail { DownloadDetail(item: detail, store: store) }
            }
            .onChange(of: itemIDs) { _, ids in
                if let detail, !ids.contains(detail.id) { self.detail = nil }
            }
            .onChange(of: recentIDs) { old, new in
                if !new.subtracting(old).isEmpty { showingRecent = true }
            }
        }
    }
}

private struct DownloadQueueHeader: View {
    @Bindable var store: DownloadStore
    let active: Int
    let waiting: Int
    private var title: String {
        if store.isPaused { return active > 0 ? "Pausing after current" : "Queue paused" }
        return active > 0 ? "In progress" : "Ready to download"
    }
    private var summary: String {
        var parts: [String] = []
        if active > 0 { parts.append("\(active) active") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                status
                Spacer(minLength: 8)
                queueControl
            }
            VStack(alignment: .leading, spacing: 12) {
                status
                queueControl
            }
        }.padding(.horizontal, 2).padding(.bottom, 4)
    }
    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(summary).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var queueControl: some View {
        Button(
            store.isPaused ? "Resume queue" : "Pause after current",
            systemImage: store.isPaused ? "play.fill" : "pause.fill"
        ) {
            store.toggleQueue()
        }.font(.caption.weight(.medium)).buttonStyle(.glass).controlSize(.small)
    }
}

private struct QueueSectionHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            Text("\(count)").font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            Spacer(minLength: 0)
        }.foregroundStyle(.primary).padding(.horizontal, 2).padding(.top, 4)
    }
}

struct LiquidPlusButton: View {
    let diameter: CGFloat
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: diameter * 0.4, weight: .light))
                .foregroundStyle(.orange)
                .frame(width: diameter, height: diameter)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Add a link")
        .accessibilityHint("Choose a link to download video or audio")
    }
}

struct DownloadRow: View {
    var item: JobItem
    var showsDisclosure = false
    private var status: String {
        switch item.job.state {
        case .queued: "Waiting in queue"
        case .failed: "Download failed"
        case .cancelled: "Cancelled"
        case .completed: "Saved to Library"
        default: item.job.state.label
        }
    }
    private var symbol: String {
        switch item.job.state {
        case .failed: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        case .completed: "checkmark.circle"
        default: "clock"
        }
    }
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Thumbnail(url: item.downloadArtwork, kind: item.job.kind)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.downloadTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(item.job.kind == .video ? "Video · \(item.job.quality.label)" : "Audio")
                    .font(.caption).foregroundStyle(.secondary)
                Label(status, systemImage: symbol).font(.caption)
                    .foregroundStyle(item.job.state == .failed ? Color.orange : Color.secondary)
                if item.job.state == .completed, let warning = item.job.warning {
                    Label(DownloadWarnings.summary(warning), systemImage: "exclamationmark.triangle").font(.caption)
                        .foregroundStyle(.orange)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if showsDisclosure {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }.foregroundStyle(.primary)
            .modifier(MediaCardStyle(padding: 14))
            .accessibilityElement(children: .combine)
    }
}
