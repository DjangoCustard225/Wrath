import SwiftUI
import UIKit
import WrathCore

/// Notices a web link on the clipboard without reading it, so iOS shows no paste prompt until you paste.
@Observable @MainActor final class CopiedLinkDetector {
    static let shared = CopiedLinkDetector()
    private(set) var hasLink = false
    @ObservationIgnored private var dismissedChange: Int?

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: PreferenceKey.suggestCopiedLinks) as? Bool ?? true
    }

    func refresh() {
        let board = UIPasteboard.general
        let change = board.changeCount
        guard Self.isEnabled, change != dismissedChange, board.hasURLs || board.hasStrings else {
            hasLink = false
            return
        }
        board.detectPatterns(for: [.probableWebURL]) { result in
            let found = (try? result.get())?.contains(.probableWebURL) == true
            Task { @MainActor in
                guard UIPasteboard.general.changeCount == change else { return }
                self.hasLink = found
            }
        }
    }

    /// Hides the banner until something new is copied.
    func dismiss() {
        dismissedChange = UIPasteboard.general.changeCount
        hasLink = false
    }
}

/// Offers to download a copied link. The system paste button reads the clipboard without a prompt.
struct CopiedLinkBanner: View {
    let detector: CopiedLinkDetector
    let paste: @MainActor (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard").font(.title3).foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Link copied").font(.subheadline.weight(.semibold))
                Text("Paste it to download").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            PasteButton(payloadType: String.self) { strings in
                Task { @MainActor in
                    detector.dismiss()
                    if let text = strings.first { paste(text) }
                }
            }
            .labelStyle(.titleOnly).buttonBorderShape(.capsule).tint(.orange)
            Button("Dismiss", systemImage: "xmark") { detector.dismiss() }
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .modifier(MediaCardStyle(padding: 14))
        .accessibilityIdentifier("copied-link-banner")
    }
}

/// Builds the share sheet for any set of saved files.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
