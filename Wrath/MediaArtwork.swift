import SwiftUI
import WrathCore

private struct ArtworkRequest: Hashable {
    let url: URL?
    let maxPixelSize: Int
}

struct MediaArtwork: View {
    let url: URL?
    let kind: MediaKind
    var maxPixelSize = 192
    @State private var image: UIImage?
    var body: some View {
        // The image overlays a flexible rectangle so decoded dimensions never
        // change the row/card layout or overflow a grid column.
        Rectangle().fill(Color(uiColor: .tertiarySystemFill))
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(
                        systemName: kind == .images ? "photo.on.rectangle" : kind == .audio ? "waveform" : "play.fill"
                    ).foregroundStyle(.secondary)
                }
            }.clipped().accessibilityHidden(true)
            .task(id: ArtworkRequest(url: url, maxPixelSize: maxPixelSize)) {
                image = nil
                if let url {
                    let loaded = await ThumbnailCache.shared.image(for: url, maxPixelSize: maxPixelSize)
                    if !Task.isCancelled { image = loaded }
                }
            }
    }
}
