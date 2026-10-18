import SwiftUI
import WrathCore

struct SourcePreview: View {
    let availability: CodecAvailability
    let kind: MediaKind
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MediaArtwork(url: availability.thumbnail, kind: kind, maxPixelSize: 1200)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 8) {
                Text(availability.title?.isEmpty == false ? availability.title! : "Media ready")
                    .font(.headline).fixedSize(horizontal: false, vertical: true)
                if availability.author?.isEmpty == false || MediaLabels.duration(availability.duration) != nil {
                    Divider()
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { metadata }
                    VStack(alignment: .leading, spacing: 6) { metadata }
                }.font(.subheadline).foregroundStyle(.secondary)
            }.padding(.horizontal, 4).padding(.bottom, 4)
        }.accessibilityElement(children: .combine)
    }
    @ViewBuilder private var metadata: some View {
        if let author = availability.author, !author.isEmpty {
            Text(author).lineLimit(2)
        }
        if let duration = MediaLabels.duration(availability.duration) {
            Label(duration, systemImage: "clock").monospacedDigit().fixedSize()
        }
    }
}

struct SourceInspectionStatus: View {
    let inspector: LinkInspector
    let url: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if inspector.sourceURL == url, let error = inspector.error {
                Text(error).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Try again", systemImage: "arrow.clockwise") { inspector.revision += 1 }
            } else if inspector.sourceURL == url, inspector.availability != nil {
                Text("No compatible formats were found for this link.").font(.subheadline).foregroundStyle(.secondary)
                Button("Check again", systemImage: "arrow.clockwise") { inspector.revision += 1 }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking available formats…")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SizeEstimateRow: View {
    let availability: CodecAvailability
    let kind: MediaKind
    let quality: Quality
    let options: DownloadOptions
    var body: some View {
        LabeledContent(
            "Estimated size",
            value: availability.estimatedSize(kind: kind, quality: quality, options: options).map {
                "≈ " + MediaLabels.bytes($0)
            } ?? "Unavailable"
        ).foregroundStyle(.secondary)
            .accessibilityHint("Approximate source size before cuts, artwork, and subtitles")
    }
}

struct SourceOptions: View {
    let availability: CodecAvailability
    let kind: MediaKind
    let quality: Quality
    let isYouTube: Bool
    @Binding var options: DownloadOptions
    var cardLayout = false
    var body: some View {
        OptionRows(cardLayout: cardLayout) {
            CodecPickers(
                kind: kind, quality: quality, availability: availability, options: $options, cardLayout: cardLayout)
            if availability.thumbnailAvailable {
                OptionDivider(shown: cardLayout)
                Toggle("Embed thumbnail", isOn: $options.embedThumbnail)
            }
            if kind == .video, !availability.subtitles.isEmpty {
                OptionDivider(shown: cardLayout)
                SubtitleOptions(tracks: availability.subtitles, options: $options, cardLayout: cardLayout)
            }
            if isYouTube {
                OptionDivider(shown: cardLayout)
                SponsorControls(options: $options, cardLayout: cardLayout)
            }
            if !availability.supports(kind: kind, quality: quality, options: options) {
                OptionDivider(shown: cardLayout)
                Text("Choose compatible codecs or another quality.").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct CodecPickers: View {
    let kind: MediaKind
    let quality: Quality
    let availability: CodecAvailability
    @Binding var options: DownloadOptions
    var cardLayout = false
    var body: some View {
        OptionRows(cardLayout: cardLayout) {
            if kind == .video {
                LabeledContent("Video codec") {
                    Picker("Video codec", selection: $options.videoCodec) {
                        ForEach(availability.videoCodecs(quality: quality), id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden().pickerStyle(.menu)
                }
            }
            if availability.mediaKinds.contains(.audio) {
                OptionDivider(shown: cardLayout && kind == .video)
                LabeledContent("Audio codec") {
                    Picker("Audio codec", selection: $options.audioCodec) {
                        ForEach(
                            availability.audioCodecs(kind: kind, quality: quality, videoCodec: options.videoCodec),
                            id: \.self
                        ) { Text($0.label).tag($0) }
                    }.labelsHidden().pickerStyle(.menu)
                }
            }
        }
    }
}

struct SubtitleOptions: View {
    let tracks: [SubtitleChoice]
    @Binding var options: DownloadOptions
    var cardLayout = false
    var body: some View {
        OptionRows(cardLayout: cardLayout) {
            Toggle("Embed subtitles", isOn: $options.embedSubtitles)
            if options.embedSubtitles {
                OptionDivider(shown: cardLayout)
                LabeledContent("Subtitle language") {
                    Picker("Subtitle language", selection: $options.subtitleTrack) {
                        Text("Automatic").tag("automatic")
                        ForEach(tracks) { track in Text(track.label).tag(track.id) }
                    }.labelsHidden().pickerStyle(.menu)
                }
            }
        }
    }
}

struct SponsorControls: View {
    @Binding var options: DownloadOptions
    var cardLayout = false
    var body: some View {
        OptionRows(cardLayout: cardLayout) {
            Toggle(
                "SponsorBlock",
                isOn: Binding(
                    get: { options.sponsorMode != .off },
                    set: { options.sponsorMode = $0 ? .remove : .off })
            )
            .accessibilityHint("Remove selected segments when enabled")
            if options.sponsorMode != .off {
                OptionDivider(shown: cardLayout)
                NavigationLink {
                    List {
                        Section {
                            ForEach(SponsorCategory.allCases, id: \.self) { category in
                                Toggle(
                                    category.label,
                                    isOn: Binding(
                                        get: { options.sponsorCategories.contains(category) },
                                        set: { enabled in
                                            if enabled {
                                                options.sponsorCategories.insert(category)
                                            } else {
                                                options.sponsorCategories.remove(category)
                                            }
                                        }))
                            }
                        } footer: {
                            if options.sponsorCategories.isEmpty {
                                Text("Choose at least one category.").foregroundStyle(.orange)
                            }
                        }
                    }.navigationTitle("Segment categories").navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        LabeledContent("Categories") {
                            Text(
                                options.sponsorCategories.isEmpty
                                    ? "Required" : "\(options.sponsorCategories.count) selected"
                            )
                            .foregroundStyle(options.sponsorCategories.isEmpty ? Color.orange : Color.secondary)
                        }
                        if cardLayout {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary).accessibilityHidden(true)
                        }
                    }
                }
            }
        }
    }
}

/// Add-link cards separate visible rows; lists retain their native individual rows.
private struct OptionRows<Content: View>: View {
    let cardLayout: Bool
    @ViewBuilder var content: Content
    var body: some View {
        if cardLayout {
            VStack(alignment: .leading, spacing: 16) { content }
        } else {
            content
        }
    }
}

private struct OptionDivider: View {
    let shown: Bool
    var body: some View { if shown { Divider() } }
}

struct SponsorOptions: View {
    @Binding var options: DownloadOptions
    var body: some View { Section("YouTube") { SponsorControls(options: $options) } }
}
