import SwiftUI
import WrathCore

struct ActiveDownloadCard: View {
    let item: JobItem
    var openDetails: (() -> Void)?
    var cancel: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var streaming: Bool { item.job.state == .processing && item.isStreaming && item.phase == .copying }
    private var transferring: Bool { item.job.state == .downloading || streaming }
    private var status: String {
        if transferring { return "Downloading" }
        return item.job.state == .resolving ? "Preparing" : "Finishing"
    }
    private var stage: String {
        if item.job.state == .resolving { return item.preparationLabel }
        return streaming ? "Downloading stream" : item.phase.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(
                    status,
                    systemImage: transferring ? "arrow.down" : item.job.state == .resolving ? "link" : "wand.and.stars"
                )
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.orange.opacity(0.1), in: Capsule())
                Spacer(minLength: 8)
                if let cancel {
                    Menu {
                        if let openDetails {
                            Button("Download details", systemImage: "info.circle", action: openDetails)
                        }
                        Button("Cancel download", systemImage: "xmark", role: .destructive, action: cancel)
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 32, height: 32).contentShape(Rectangle())
                    }.accessibilityLabel("Active download actions")
                }
            }
            if let openDetails {
                Button(action: openDetails) { content }.buttonStyle(.plain)
                    .accessibilityHint("Opens download details")
            } else {
                content
            }
        }.foregroundStyle(.primary).modifier(MediaCardStyle(padding: 18))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            mediaHeader
            VStack(alignment: .leading, spacing: 10) {
                if item.job.state == .downloading {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            progressLabel
                            Spacer(minLength: 12)
                            byteCount
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            progressLabel
                            byteCount
                        }
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(stage).font(.subheadline.weight(.medium))
                        Spacer(minLength: 12)
                        if item.progressKnown {
                            progressLabel
                        } else {
                            ProgressView().controlSize(.small).accessibilityLabel(status)
                        }
                    }
                }
                if item.progressKnown {
                    ProgressView(value: min(1, max(0, item.progress)))
                        .progressViewStyle(.linear).tint(.orange)
                        .animation(reduceMotion ? nil : .linear(duration: 0.25), value: item.progress)
                        .accessibilityLabel(status + " progress")
                }
            }
            if item.job.state == .downloading {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 10) {
                        speedMetric
                        timeMetric
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        speedMetric
                        timeMetric
                    }
                }
            }
        }.contentShape(Rectangle())
    }

    private var speedMetric: some View {
        DownloadMetric(
            title: "Speed", symbol: "arrow.down",
            value: item.speed > 0 ? MediaLabels.bytes(Int64(item.speed)) + "/s" : "—")
    }
    private var timeMetric: some View {
        DownloadMetric(
            title: "Time left", symbol: "clock",
            value: item.progressKnown ? item.eta.flatMap { MediaLabels.shortETA($0) } ?? "—" : "—")
    }

    private var mediaHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                MediaArtwork(url: item.downloadArtwork, kind: item.job.kind, maxPixelSize: 384)
                    .frame(width: 88, height: 62).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(item.downloadTitle).font(.headline).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                Text(item.downloadFormat).font(.caption).foregroundStyle(.secondary)
                if let source = item.job.sourceURL.host {
                    Text(source).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.foregroundStyle(.primary).contentShape(Rectangle())
    }

    @ViewBuilder private var progressLabel: some View {
        if item.progressKnown {
            Text(item.progress, format: .percent.precision(.fractionLength(0)))
                .font(.title2.weight(.semibold)).monospacedDigit().accessibilityHidden(true)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Downloading…").font(.subheadline.weight(.medium))
            }
        }
    }
    private var byteCount: some View {
        Text(
            item.expectedBytes > 0
                ? "\(MediaLabels.bytes(item.receivedBytes)) / \(MediaLabels.bytes(item.expectedBytes))"
                : "\(MediaLabels.bytes(item.receivedBytes)) downloaded"
        )
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
}

extension JobItem {
    var downloadTitle: String {
        if [.queued, .resolving].contains(job.state), let title = job.codecAvailability?.title, !title.isEmpty {
            return title
        }
        return job.title
    }
    var downloadArtwork: URL? { job.thumbnail ?? job.codecAvailability?.thumbnail }
    var downloadFormat: String { job.kind == .video ? "Video · \(job.quality.label)" : "Audio · Original quality" }
}

private struct DownloadMetric: View {
    let title: String
    let symbol: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }
}
