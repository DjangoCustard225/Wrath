import SwiftUI
import WrathCore

struct DownloadProgressView: View {
    let item: JobItem
    let cancel: () -> Void
    let togglePause: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var streaming: Bool { item.job.state == .processing && item.isStreaming && item.phase == .copying }
    private var transferring: Bool { item.job.state == .downloading || streaming }
    private var status: String {
        if item.isPaused { return "Paused" }
        if transferring { return "Downloading" }
        return item.job.state == .resolving ? "Preparing" : "Finishing"
    }
    private var stage: String {
        if item.isPaused { return "Download paused" }
        if item.job.state == .resolving { return item.preparationLabel }
        return streaming ? "Downloading stream" : item.phase.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            mediaHeader
            Label(
                status,
                systemImage: item.isPaused
                    ? "pause" : transferring ? "arrow.down" : item.job.state == .resolving ? "link" : "wand.and.stars"
            )
            .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.orange.opacity(0.1), in: Capsule())
            content
            if transferring {
                Button(action: togglePause) {
                    Label(
                        item.isPaused ? "RESUME DOWNLOAD" : "PAUSE DOWNLOAD",
                        systemImage: item.isPaused ? "play.fill" : "pause.fill"
                    )
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .tracking(1.8).frame(maxWidth: .infinity, minHeight: 28)
                }
                .wrathGlassButton().buttonBorderShape(.capsule).controlSize(.large)
                .accessibilityLabel(item.isPaused ? "Resume download" : "Pause download")
                .accessibilityIdentifier("pause-download")
            }
            Button(role: .destructive, action: cancel) {
                Text("CANCEL DOWNLOAD")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .tracking(1.8).frame(maxWidth: .infinity, minHeight: 28)
            }
            .wrathGlassButton(clear: true).buttonBorderShape(.capsule).controlSize(.large)
            .foregroundStyle(.primary).accessibilityLabel("Cancel download")
            .accessibilityIdentifier("cancel-download")
        }.foregroundStyle(.primary).modifier(MediaCardStyle())
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
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
                        } else if !item.isPaused {
                            ProgressView().controlSize(.small).accessibilityLabel(status)
                        }
                    }
                }
                if item.progressKnown {
                    ProgressView(value: min(1, max(0, item.progress)))
                        .progressViewStyle(.linear).tint(.orange)
                        .animation(reduceMotion ? nil : .linear(duration: 0.25), value: item.progress)
                        .accessibilityLabel(status + " progress")
                        .accessibilityIdentifier("download-progress-bar")
                } else if item.isPaused {
                    Capsule().fill(Color.orange.opacity(0.16)).frame(height: 5)
                        .accessibilityElement().accessibilityLabel("Paused progress")
                        .accessibilityValue("Paused; total unavailable")
                        .accessibilityIdentifier("download-progress-bar")
                } else {
                    IndeterminateDownloadBar()
                        .accessibilityElement().accessibilityLabel(status + " progress")
                        .accessibilityValue("In progress; total unavailable")
                        .accessibilityIdentifier("download-progress-bar")
                }
            }
            if item.job.state == .downloading {
                Divider()
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
        }
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
        VStack(alignment: .leading, spacing: 14) {
            MediaArtwork(url: item.downloadArtwork, kind: item.job.kind, maxPixelSize: 1200)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.downloadTitle).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(item.downloadFormat).font(.caption).foregroundStyle(.secondary)
                if let source = item.job.sourceURL.host {
                    Text(source).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.foregroundStyle(.primary)
    }

    @ViewBuilder private var progressLabel: some View {
        if item.progressKnown {
            Text(item.progress, format: .percent.precision(.fractionLength(0)))
                .font(.title2.weight(.semibold)).monospacedDigit().accessibilityHidden(true)
        } else if item.isPaused {
            Text("Download paused").font(.subheadline.weight(.medium))
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

private struct IndeterminateDownloadBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Color.orange.opacity(0.16))
                .overlay(alignment: .leading) {
                    if reduceMotion {
                        Capsule().fill(Color.orange.opacity(0.45))
                    } else {
                        Capsule().fill(.orange)
                            .frame(width: geometry.size.width * 0.3)
                            .offset(x: moving ? geometry.size.width : -geometry.size.width * 0.3)
                            .animation(.linear(duration: 1.3).repeatForever(autoreverses: false), value: moving)
                    }
                }
        }
        .frame(height: 5).clipShape(Capsule())
        .onAppear { moving = true }
        .onDisappear { moving = false }
    }
}

extension JobItem {
    var downloadTitle: String {
        if job.state == .resolving, let title = job.codecAvailability?.title, !title.isEmpty {
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
            .accessibilityElement(children: .combine)
    }
}
