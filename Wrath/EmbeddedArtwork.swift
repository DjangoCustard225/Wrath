import Foundation
import ImageIO
import UniformTypeIdentifiers

actor EmbeddedArtwork {
    static let shared = EmbeddedArtwork()
    func prepare(url: URL?, destination: URL) async throws -> URL {
        guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            throw EngineFailure(
                message: "This source did not provide a thumbnail. Turn off Embed thumbnail to continue.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
            !data.isEmpty, data.count <= 8 * 1024 * 1024,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1200, kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary),
            let output = CGImageDestinationCreateWithURL(
                destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw EngineFailure(message: "Could not load the thumbnail. Retry or turn off Embed thumbnail.")
        }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            throw EngineFailure(message: "Could not prepare the embedded thumbnail.")
        }
        return destination
    }
}
