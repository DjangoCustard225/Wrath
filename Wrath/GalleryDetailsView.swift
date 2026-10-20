import SwiftUI
import WrathCore

private enum GallerySheet: Identifiable {
    case preview(Int)
    case rename, share
    var id: String {
        switch self {
        case .preview(let index): "preview-\(index)"
        case .rename: "rename"
        case .share: "share"
        }
    }
}

struct GalleryDetailsView: View {
    let item: JobItem
    @Bindable var store: DownloadStore
    @State private var sheet: GallerySheet?

    var body: some View {
        let urls = item.galleryURLs
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.job.title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    Text("\(urls.count) photos · \(MediaLabels.bytes(item.job.bytes))")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if !item.job.author.isEmpty { Text(item.job.author).font(.subheadline).foregroundStyle(.secondary) }
                    if let warning = DownloadWarnings.visible(item.job.warning, for: item.job.kind) {
                        Text(warning).font(.footnote).foregroundStyle(.secondary)
                    }
                    Link("Open source", destination: item.job.sourceURL).font(.subheadline)
                }.frame(maxWidth: .infinity, alignment: .leading).modifier(MediaCardStyle(padding: 18))
                ForEach(Array(urls.enumerated()), id: \.element) { index, url in
                    Button {
                        sheet = .preview(index)
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            MediaArtwork(url: url, kind: .images, maxPixelSize: 1200)
                                .aspectRatio(4 / 3, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            Text("Photo \(index + 1)").font(.subheadline.weight(.medium))
                        }.foregroundStyle(.primary).modifier(MediaCardStyle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { ShareLink(item: url) { Label("Share photo", systemImage: "square.and.arrow.up") } }
                }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .wrathSoftScrollEdges()
        .navigationTitle("Gallery").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Share photos", systemImage: "square.and.arrow.up") { sheet = .share }
                    Button("Rename gallery", systemImage: "pencil") { sheet = .rename }
                } label: {
                    Label("Gallery actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $sheet) { presented in
            switch presented {
            case .preview(let index):
                if let first = urls.first {
                    FilePreview(url: first, additionalURLs: Array(urls.dropFirst()), selectedIndex: index)
                }
            case .rename: RenameFileSheet(item: item, store: store)
            case .share: GalleryShareSheet(urls: urls)
            }
        }
    }
}

private struct GalleryShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
