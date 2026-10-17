import SwiftUI

// Adapted from Quby's CardComponents and TorrentDetail layout.
// Copyright (c) 2026 Ammar Haseeb. MIT license: Resources/Licenses/Quby.txt.
struct DetailCardSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).padding(.horizontal, 2).accessibilityAddTraits(.isHeader)
            content
        }
    }
}

struct DetailMetricCard: View {
    let title: String
    let value: String
    let symbol: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .modifier(MediaCardStyle(padding: 16, cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

struct DetailValueRow: View {
    let title: String
    let value: String
    var copyable = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).foregroundStyle(.secondary)
                    valueText
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    Text(title).foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 12)
                    valueText.multilineTextAlignment(.trailing)
                }
            }
        }
        .font(.subheadline).padding(.vertical, 15)
        .contextMenu {
            if copyable {
                Button("Copy \(title.lowercased())", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = value
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var valueText: some View {
        Text(value).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}
