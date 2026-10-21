import SwiftUI
import WrathCore

struct DownloadsView: View {
    @Bindable var store: DownloadStore
    let add: () -> Void
    let browse: () -> Void
    let showProgress: (UUID) -> Void
    var body: some View {
        NavigationStack {
            Group {
                if let item = store.items.first(where: { $0.job.state.isActive }) {
                    ScrollView {
                        Button {
                            showProgress(item.id)
                        } label: {
                            ActiveDownloadRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("open-download-progress")
                        .accessibilityHint("Show download details and controls")
                        .padding(.horizontal, 18).padding(.top, 12)
                    }
                    .wrathSoftScrollEdges()
                } else if store.isDownloadOccupied {
                    ProgressView("Finishing up…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LiquidPlusButton(diameter: 104, action: add)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Wrath")
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: browse) {
                        Label("Browse", systemImage: "safari")
                    }
                    .accessibilityLabel("Browse the web")
                    .accessibilityHint("Open the built-in browser to grab media from a page")
                }
            }
        }
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
        .wrathGlassButton()
        .buttonBorderShape(.circle)
        .accessibilityLabel("Add a link")
        .accessibilityHint("Choose a link to download video, audio, or photos")
    }
}

private struct ActiveDownloadRow: View {
    let item: JobItem
    var body: some View {
        HStack(spacing: 12) {
            MediaArtwork(url: item.downloadArtwork, kind: item.job.kind, maxPixelSize: 256)
                .frame(width: 72, height: 54).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.downloadTitle).font(.headline).lineLimit(2)
                Text(status).font(.caption).foregroundStyle(.secondary)
                if item.progressKnown {
                    ProgressView(value: min(1, max(0, item.progress))).tint(.orange)
                } else if !item.isPaused {
                    ProgressView().controlSize(.mini)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary).modifier(MediaCardStyle())
        .accessibilityElement(children: .combine)
    }
    private var status: String {
        if item.isPaused { return "Paused" }
        switch item.job.state {
        case .resolving: return item.preparationLabel
        case .downloading:
            return item.progressKnown ? "Downloading · \(Int(min(1, max(0, item.progress)) * 100))%" : "Downloading"
        default: return item.phase.label
        }
    }
}

struct DownloadProgressSheet: View {
    let item: JobItem
    let cancel: () -> Void
    let togglePause: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var detent = PresentationDetent.large

    var body: some View {
        NavigationStack {
            ScrollView {
                DownloadProgressView(item: item, cancel: cancel, togglePause: togglePause)
                    .frame(maxWidth: 600).frame(maxWidth: .infinity)
                    .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 24)
            }
            .wrathSoftScrollEdges()
            .navigationTitle("Download").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("dismiss-download-progress")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("download-progress-sheet")
    }
}
