import Foundation
import ImageIO
import UIKit

actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private let images = NSCache<NSString, UIImage>()
    private var session: URLSession
    private let cache: URLCache
    private var generation = 0
    init() {
        images.totalCostLimit = 16 * 1024 * 1024
        cache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 32 * 1024 * 1024, diskPath: "WrathThumbnails")
        session = Self.makeSession()
    }
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // Cache writes are owned by this actor so an in-flight response cannot
        // repopulate the cache after the user clears it.
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }
    var diskBytes: Int64 { Int64(cache.currentDiskUsage) }
    func clear() {
        generation += 1
        session.invalidateAndCancel()
        images.removeAllObjects()
        cache.removeAllCachedResponses()
        session = Self.makeSession()
    }
    func image(for url: URL, maxPixelSize: Int = 192) async -> UIImage? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let pixelSize = min(1200, max(64, maxPixelSize))
        let key = "\(pixelSize)|\(url.absoluteString)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        let requestGeneration = generation
        do {
            let request = URLRequest(url: url)
            let cached = cache.cachedResponse(for: request)
            let data: Data
            let response: URLResponse
            if let cached {
                data = cached.data
                response = cached.response
            } else {
                (data, response) = try await session.data(for: request)
            }
            try Task.checkCancellation()
            guard requestGeneration == generation,
                let response = response as? HTTPURLResponse, response.statusCode == 200,
                data.count < 8 * 1024 * 1024,
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let cgImage = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary)
            else { return nil }
            let image = UIImage(cgImage: cgImage)
            if cached == nil {
                cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
            }
            images.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
            return image
        } catch { return nil }
    }
}
