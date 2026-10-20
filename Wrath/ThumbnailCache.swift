import Foundation
import ImageIO
import UIKit

actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private let images = NSCache<NSString, UIImage>()
    private var session: URLSession
    private let cache: URLCache
    private let protocolClasses: [AnyClass]?
    private var generation = 0
    private struct PendingImage {
        let id: UUID
        let task: Task<UIImage?, Never>
        var waiters: Set<UUID>
    }
    private var pending: [String: PendingImage] = [:]
    init(protocolClasses: [AnyClass]? = nil) {
        self.protocolClasses = protocolClasses
        images.totalCostLimit = 16 * 1024 * 1024
        cache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 32 * 1024 * 1024, diskPath: "WrathThumbnails")
        session = Self.makeSession(protocolClasses: protocolClasses)
    }
    private static func makeSession(protocolClasses: [AnyClass]?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // Cache writes are owned by this actor so an in-flight response cannot
        // repopulate the cache after the user clears it.
        config.urlCache = nil
        if let protocolClasses { config.protocolClasses = protocolClasses }
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }
    var diskBytes: Int64 { Int64(cache.currentDiskUsage) }
    func clear() {
        generation += 1
        for request in pending.values { request.task.cancel() }
        pending.removeAll()
        session.invalidateAndCancel()
        images.removeAllObjects()
        cache.removeAllCachedResponses()
        session = Self.makeSession(protocolClasses: protocolClasses)
    }
    func image(for url: URL, maxPixelSize: Int = 192) async -> UIImage? {
        guard !Task.isCancelled, url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        let pixelSize = min(1200, max(64, maxPixelSize))
        let key = "\(pixelSize)|\(url.absoluteString)"
        if let cached = images.object(forKey: key as NSString) { return cached }
        let waiter = UUID()
        let request: PendingImage
        if var current = pending[key] {
            current.waiters.insert(waiter)
            pending[key] = current
            request = current
        } else {
            let requestGeneration = generation
            request = PendingImage(
                id: UUID(),
                task: Task { await loadImage(for: url, pixelSize: pixelSize, key: key, generation: requestGeneration) },
                waiters: [waiter])
            pending[key] = request
        }
        let image = await withTaskCancellationHandler {
            await request.task.value
        } onCancel: {
            Task { await self.release(waiter, for: key, requestID: request.id) }
        }
        release(waiter, for: key, requestID: request.id)
        return Task.isCancelled ? nil : image
    }

    private func release(_ waiter: UUID, for key: String, requestID: UUID) {
        guard var request = pending[key], request.id == requestID else { return }
        request.waiters.remove(waiter)
        if request.waiters.isEmpty {
            request.task.cancel()
            pending[key] = nil
        } else {
            pending[key] = request
        }
    }

    private func loadImage(for url: URL, pixelSize: Int, key: String, generation: Int) async -> UIImage? {
        guard !Task.isCancelled, generation == self.generation else { return nil }
        let source: CGImageSource?
        var fetched: (URLRequest, CachedURLResponse)?
        if url.isFileURL {
            source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        } else {
            let request = URLRequest(url: url)
            let cached = cache.cachedResponse(for: request)
            do {
                let (data, response): (Data, URLResponse)
                if let cached {
                    (data, response) = (cached.data, cached.response)
                } else {
                    (data, response) = try await session.data(for: request)
                }
                guard !Task.isCancelled, generation == self.generation,
                    let response = response as? HTTPURLResponse, response.statusCode == 200,
                    data.count < 8 * 1024 * 1024
                else { return nil }
                source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
                if source != nil, cached == nil {
                    fetched = (request, CachedURLResponse(response: response, data: data))
                }
            } catch { return nil }
        }
        guard let source,
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { return nil }
        if let (request, response) = fetched { cache.storeCachedResponse(response, for: request) }
        let image = UIImage(cgImage: cgImage)
        images.setObject(image, forKey: key as NSString, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
}
