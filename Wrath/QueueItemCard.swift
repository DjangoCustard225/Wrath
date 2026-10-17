import SwiftUI
import WrathCore

struct QueueItemCard: View {
    let item: JobItem
    var position: Int?
    var paused = false
    let open: () -> Void
    let remove: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var status: String {
        switch item.job.state {
        case .queued: paused ? "Queue paused" : position == 1 ? "Up next" : "Waiting"
        case .failed: "Download failed"
        case .cancelled: "Cancelled"
        default: item.job.state.label
        }
    }
    private var symbol: String {
        switch item.job.state {
        case .queued: paused ? "pause.circle" : "clock"
        case .failed: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        default: "arrow.down.circle"
        }
    }
    private var estimate: String? {
        item.job.codecAvailability?.estimatedSize(
            kind: item.job.kind, quality: item.job.quality, options: item.job.effectiveOptions
        )
        .map { "≈ " + MediaLabels.bytes($0) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 12) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        MediaArtwork(url: item.downloadArtwork, kind: item.job.kind, maxPixelSize: 192)
                            .frame(width: 68, height: 68).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            if let position {
                                Text("\(position)").font(.caption2.weight(.bold)).monospacedDigit()
                                    .frame(minWidth: 18, minHeight: 18)
                                    .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                                    .accessibilityLabel("Queue position \(position)")
                            }
                            Label(status, systemImage: symbol).font(.caption.weight(.medium))
                                .foregroundStyle(item.job.state == .failed ? Color.orange : Color.secondary)
                        }
                        Text(item.downloadTitle).font(.subheadline.weight(.semibold))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        Text(item.downloadFormat).font(.caption).foregroundStyle(.secondary)
                        if item.job.state == .queued, let estimate {
                            Text(estimate).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.foregroundStyle(.primary).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityElement(children: .combine)
                .accessibilityHint("Opens download details and options")
            Menu {
                Button("Download details", systemImage: "info.circle", action: open)
                Button(
                    item.job.state == .queued ? "Cancel download" : "Remove entry",
                    systemImage: item.job.state == .queued ? "xmark" : "trash", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
                    .frame(width: 32, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Actions for \(item.downloadTitle)")
        }.modifier(MediaCardStyle(padding: 14))
    }
}
