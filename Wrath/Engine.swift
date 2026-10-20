import Foundation
import WrathBridge
import WrathCore

struct EngineFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class OperationToken: @unchecked Sendable {
    let pointer = wrath_token_create()!
    var isCancelled: Bool { wrath_is_cancelled(pointer) != 0 }
    func cancel() { wrath_token_cancel(pointer) }
    func setPaused(_ paused: Bool) { wrath_token_set_paused(pointer, paused ? 1 : 0) }
    deinit { wrath_token_free(pointer) }
}

struct DownloadEvent: Decodable, Sendable {
    let type: String
    let plan: MediaPlan?
    let index: Int?
    let bytes: Int64?
    let total: Int64?
    let speed: Double?
    let eta: Double?
    let finished: Bool?
    let fraction: Double?
    let imageIndex: Int?
    let imageCount: Int?
}

final class MediaEngine: @unchecked Sendable {
    static let shared = MediaEngine()
    // Inspections are serialized separately from long-running upstream downloads.
    private let condition = NSCondition()
    private var work: [() -> Void] = []
    // Local processing and metadata probing stay off the Python worker threads.
    private let processingQueue = DispatchQueue(label: "Wrath.MediaProcessing", qos: .utility)
    private let downloadQueue = DispatchQueue(label: "Wrath.YtDlpDownload", qos: .utility)
    private let metadataQueue = DispatchQueue(label: "Wrath.LocalMediaInfo", qos: .utility)
    private lazy var thread: Thread = {
        let t = Thread { [self] in
            while true {
                condition.lock()
                while work.isEmpty { condition.wait() }
                let next = work.removeFirst()
                condition.unlock()
                autoreleasepool { next() }
            }
        }
        t.name = "Wrath.MediaEngine"
        t.qualityOfService = .utility
        t.start()
        return t
    }()
    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            _ = thread
            condition.lock()
            work.append {
                do { continuation.resume(returning: try operation()) } catch { continuation.resume(throwing: error) }
            }
            condition.signal()
            condition.unlock()
        }
    }
    private func process<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await dispatch(on: processingQueue, operation: operation)
    }
    private func dispatch<T>(on queue: DispatchQueue, operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                autoreleasepool {
                    do { continuation.resume(returning: try operation()) } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    func download(
        job: DownloadJob, cache: URL, directory: URL, token: OperationToken,
        event: @escaping @MainActor @Sendable (DownloadEvent) -> Void
    ) async throws -> MediaPlan {
        let social = try await SocialAccessStore.shared.snapshot(for: job.sourceURL)
        let options = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job.effectiveOptions))
        let request: [String: Any] = [
            "url": job.sourceURL.absoluteString, "kind": job.kind.rawValue, "quality": job.quality.rawValue,
            "cache": cache.path, "directory": directory.path, "options": options,
            "exactQuality": job.codecAvailability?.exactQualities ?? false,
            "socialAccess": social,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let payload = String(decoding: data, as: UTF8.self)
        let (stream, continuation) = AsyncStream<DownloadEvent>.makeStream()
        let consumer = Task {
            for await value in stream { await event(value) }
        }
        do {
            let plan = try await withTaskCancellationHandler {
                try await dispatch(on: downloadQueue) {
                    final class Reporter {
                        let continuation: AsyncStream<DownloadEvent>.Continuation
                        init(_ continuation: AsyncStream<DownloadEvent>.Continuation) {
                            self.continuation = continuation
                        }
                    }
                    let reporter = Reporter(continuation)
                    let context = Unmanaged.passUnretained(reporter).toOpaque()
                    guard !token.isCancelled else { throw CancellationError() }
                    guard
                        let raw = wrath_download(
                            Bundle.main.bundlePath, payload, token.pointer,
                            { json, context in
                                guard let json, let context,
                                    let value = try? JSONDecoder().decode(
                                        DownloadEvent.self, from: Data(String(cString: json).utf8))
                                else { return }
                                Unmanaged<Reporter>.fromOpaque(context).takeUnretainedValue().continuation.yield(value)
                            }, context)
                    else { throw EngineFailure(message: "The download engine returned no result.") }
                    defer { wrath_free(raw) }
                    withExtendedLifetime(reporter) {}
                    guard !token.isCancelled else { throw CancellationError() }
                    struct Reply: Decodable {
                        let plan: MediaPlan?
                        let error: String?
                    }
                    let reply = try JSONDecoder().decode(Reply.self, from: Data(String(cString: raw).utf8))
                    guard let plan = reply.plan else { throw EngineFailure(message: reply.error ?? "No media found.") }
                    return plan
                }
            } onCancel: {
                token.cancel()
            }
            continuation.finish()
            await consumer.value
            return plan
        } catch {
            continuation.finish()
            await consumer.value
            throw error
        }
    }
    func inspect(url: URL, cache: URL, token: OperationToken) async throws -> CodecAvailability {
        let social = try await SocialAccessStore.shared.snapshot(for: url)
        return try await withTaskCancellationHandler {
            try await perform {
                // A cancelled inspection may have waited behind extraction or
                // remux work. Drop it before entering the embedded interpreter.
                guard !token.isCancelled else { throw CancellationError() }
                let request: [String: Any] = [
                    "url": url.absoluteString, "kind": "video", "quality": 0,
                    "cache": cache.path, "operation": "inspect",
                    "socialAccess": social,
                ]
                let data = try JSONSerialization.data(withJSONObject: request)
                guard
                    let raw = wrath_extract(
                        Bundle.main.bundlePath, cache.path, String(decoding: data, as: UTF8.self), token.pointer)
                else {
                    throw EngineFailure(message: "Could not check available codecs.")
                }
                defer { wrath_free(raw) }
                guard !token.isCancelled else { throw CancellationError() }
                struct Reply: Decodable {
                    let availability: CodecAvailability?
                    let error: String?
                }
                let reply = try JSONDecoder().decode(Reply.self, from: Data(String(cString: raw).utf8))
                guard let availability = reply.availability else {
                    throw EngineFailure(message: reply.error ?? "Could not check available codecs.")
                }
                return availability
            }
        } onCancel: {
            token.cancel()
        }
    }
    func clearExtractorCache(in support: URL) async throws {
        // Wait for downloading, then serialize cache removal with inspections.
        try await dispatch(on: downloadQueue) {}
        try await perform {
            let token = OperationToken()
            guard
                let raw = wrath_extract(
                    Bundle.main.bundlePath, support.path, #"{"operation":"clearInspectionCache"}"#, token.pointer)
            else { throw EngineFailure(message: "Could not clear checked media details.") }
            defer { wrath_free(raw) }
            struct Reply: Decodable {
                let cleared: Bool?
                let error: String?
            }
            let reply = try JSONDecoder().decode(Reply.self, from: Data(String(cString: raw).utf8))
            guard reply.cleared == true else {
                throw EngineFailure(message: reply.error ?? "Could not clear checked media details.")
            }
            try CacheMaintenance.clearExtractor(in: support)
        }
    }
    func probe(_ file: URL, token: OperationToken = OperationToken()) async -> SavedMediaInfo? {
        guard file.isFileURL else { return nil }
        return try? await dispatch(on: metadataQueue) {
            guard let raw = wrath_probe_media(file.path, token.pointer) else { return nil as SavedMediaInfo? }
            defer { wrath_free(raw) }
            return try JSONDecoder().decode(SavedMediaInfo.self, from: Data(String(cString: raw).utf8))
        }
    }
    func remux(
        inputs: [URL], headers: [String], output: URL, audioOnly: Bool, token: OperationToken,
        cover: URL? = nil, segments: [SponsorSegment] = [], sponsorMode: SponsorMode = .off,
        subtitle: MediaSubtitle? = nil,
        progress: @escaping @Sendable (ProcessingPhase, Double?) -> Void
    ) async throws -> URL {
        try await process {
            final class Reporter {
                let callback: @Sendable (ProcessingPhase, Double?) -> Void
                init(_ c: @escaping @Sendable (ProcessingPhase, Double?) -> Void) { callback = c }
            }
            let reporter = Reporter(progress)
            let context = Unmanaged.passUnretained(reporter).toOpaque()
            var error = [CChar](repeating: 0, count: 512)
            var ext = [CChar](repeating: 0, count: 16)
            let nativeSegments = segments.map {
                WrathSegment(start: $0.start, end: $0.end, category: Int32($0.category.index))
            }
            let texts = (subtitle?.cues ?? []).map { strdup($0.text) }
            defer {
                for text in texts { free(text) }
            }
            let nativeCues = zip(subtitle?.cues ?? [], texts).map {
                WrathSubtitleCue(start: $0.0.start, end: $0.0.end, text: $0.1.map { UnsafePointer($0) })
            }
            let result = nativeSegments.withUnsafeBufferPointer { buffer in
                nativeCues.withUnsafeBufferPointer { captions in
                    wrath_remux_with_status(
                        inputs[0].isFileURL ? inputs[0].path : inputs[0].absoluteString, headers[0],
                        inputs.count > 1 ? (inputs[1].isFileURL ? inputs[1].path : inputs[1].absoluteString) : "",
                        headers.count > 1 ? headers[1] : "", output.path, audioOnly ? 1 : 0,
                        token.pointer, nil, context, &error, Int32(error.count), &ext, Int32(ext.count),
                        cover?.path ?? "",
                        buffer.baseAddress, Int32(buffer.count),
                        sponsorMode == .remove ? 2 : (sponsorMode == .chapters ? 1 : 0),
                        captions.baseAddress, Int32(captions.count), subtitle?.language ?? "und",
                        subtitle?.name ?? "Subtitles",
                        { phase, value, context in
                            guard let context, let stage = ProcessingPhase(rawValue: phase) else { return }
                            Unmanaged<Reporter>.fromOpaque(context).takeUnretainedValue().callback(
                                stage, value.isFinite && value >= 0 ? min(1, value) : nil)
                        })
                }
            }
            withExtendedLifetime(reporter) {}
            if result < 0 { throw EngineFailure(message: String(cString: error)) }
            return output.appendingPathExtension(String(cString: ext))
        }
    }
}
