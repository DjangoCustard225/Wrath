import SwiftUI
import WrathCore

// Layout adapted from Quby’s AddTorrentView.
// Copyright (c) 2026 Ammar Haseeb. MIT license: Resources/Licenses/Quby.txt.

/// A scrolling, width-limited page on the grouped background used by the add-link flow.
struct AddLinkPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .wrathSoftScrollEdges()
        .scrollDismissesKeyboard(.interactively)
    }
}

/// The prominent full-width action pinned to the bottom of an add-link page.
struct BottomBarActionButton: View {
    let title: String
    let systemImage: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline).frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
        .disabled(!enabled)
        .frame(maxWidth: 600).frame(maxWidth: .infinity)
        .padding(.horizontal, 18).padding(.vertical, 12)
    }
}

/// The link field with its host, validation status and, for Reddit and Instagram, account access.
struct LinkSourceCard: View {
    @Binding var link: String
    let url: URL?
    let checked: Bool
    let socialSite: SocialPlatform?
    let focus: FocusState<Bool>.Binding
    let submit: () -> Void
    let connect: (SocialPlatform) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "link").font(.title2).foregroundStyle(.orange)
                    .frame(width: 50, height: 50)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Media link").font(.headline)
                    Text(url?.host() ?? "Video, audio, or photos from a link")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Divider()
            TextField("Paste a media link", text: $link, axis: .vertical)
                .font(.subheadline).lineLimit(1...5)
                .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never)
                .autocorrectionDisabled().focused(focus).submitLabel(.next).onSubmit(submit)
                .accessibilityLabel("Media link")
            status.font(.caption)
            if let socialSite {
                Divider()
                SocialAccessRow(site: socialSite) { connect(socialSite) }
            }
        }
        .modifier(MediaCardStyle(padding: 20))
    }

    @ViewBuilder private var status: some View {
        if checked {
            Label("Link checked", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && url == nil {
            Label("Enter a valid link", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        }
    }
}

private struct SocialAccessRow: View {
    let site: SocialPlatform
    let connect: () -> Void
    @State private var access = SocialAccessStore.shared

    private var connected: Bool { access.cookieCounts[site, default: 0] > 0 }

    var body: some View {
        if site == .reddit {
            Text(
                "Copy the full Reddit post URL from your browser’s address bar, not the Reddit app. Use a link containing /comments/."
            )
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("reddit-browser-link-note")
        }
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(site.name + " access").font(.subheadline.weight(.medium))
                Text(connected ? "Cookies saved" : "Sign in if this link requires an account")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(connected ? "Reconnect" : "Connect", action: connect).buttonStyle(.bordered)
        }
    }
}

/// Media kind, quality and estimated size for a video or audio link.
struct FormatCard: View {
    let availability: CodecAvailability
    @Binding var kind: MediaKind
    @Binding var quality: Quality
    let options: DownloadOptions

    var body: some View {
        DetailCardSection(title: "Save as") {
            VStack(spacing: 16) {
                Picker("Save as", selection: $kind) {
                    ForEach(availability.mediaKinds, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.pickerStyle(.segmented)
                if kind == .video {
                    Divider()
                    LabeledContent("Quality") {
                        Picker("Quality", selection: $quality) {
                            ForEach(availability.qualities, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden().pickerStyle(.menu)
                    }
                }
                Divider()
                SizeEstimateRow(availability: availability, kind: kind, quality: quality, options: options)
            }.font(.subheadline).modifier(MediaCardStyle(padding: 16))
        }
    }
}

/// What a photo gallery download will save.
struct GalleryCard: View {
    let gallery: GalleryInfo

    var body: some View {
        DetailCardSection(title: "Photos") {
            VStack(alignment: .leading, spacing: 14) {
                LabeledContent("Images", value: String(gallery.count))
                Divider()
                LabeledContent("Quality", value: "Original")
                Divider()
                Text("Saved together as one gallery in Library. Size is available after downloading.")
                    .font(.footnote).foregroundStyle(.secondary)
                if gallery.skippedVideos > 0 {
                    Divider()
                    Text("This downloads images only. Video or unsupported linked attachments are not included.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.modifier(MediaCardStyle(padding: 16))
        }
    }
}
