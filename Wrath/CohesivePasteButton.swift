import SwiftUI
import UIKit

struct CohesivePasteButton: View {
    let pasted: (String) -> Void
    @State private var canPaste = UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings

    var body: some View {
        Button {
            let clipboard = UIPasteboard.general
            if let value = clipboard.url?.absoluteString ?? clipboard.string { pasted(value) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard").font(.body.weight(.medium))
                Text("PASTE LINK")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .tracking(1.8)
            }
            .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
        .tint(.orange).foregroundStyle(.white).disabled(!canPaste)
        .accessibilityLabel("Paste link")
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            refreshAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshAvailability()
        }
    }
    private func refreshAvailability() {
        canPaste = UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings
    }
}
