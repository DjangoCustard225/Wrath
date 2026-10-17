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
    deinit { wrath_token_free(pointer) }
}

final class MediaEngine: @unchecked Sendable {
    static let shared = MediaEngine()
    // CPython's thread state stays on one dedicated thread, including across jobs.
    private let condition = NSCondition()
    private var work: [() -> Void] = []
    // FFmpeg may read an entire HLS stream. It must not occupy Python's
    // dedicated thread while the user is inspecting another link.
    private let processingQueue = DispatchQueue(label: "Wrath.MediaProcessing", qos: .utility)
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
    func extract(job: DownloadJob, cache: URL, token: OperationToken) async throws -> MediaPlan {
        try await perform {
            let options = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job.effectiveOptions))
            let request: [String: Any] = [
                "url": job.sourceURL.absoluteString, "kind": job.kind.rawValue, "quality": job.quality.rawValue,
                "cache": cache.path, "options": options,
                "exactQuality": job.codecAvailability?.exactQualities ?? false,
            ]
            let data = try JSONSerialization.data(withJSONObject: request)
            let raw = wrath_extract(
                Bundle.main.bundlePath, cache.path, String(decoding: data, as: UTF8.self), token.pointer)
            guard let raw else { throw EngineFailure(message: "The extraction engine returned no result.") }
            defer { wrath_free(raw) }
            struct Reply: Decodable {
                let plan: MediaPlan?
                let error: String?
            }
            let reply = try JSONDecoder().decode(Reply.self, from: Data(String(cString: raw).utf8))
            guard let plan = reply.plan else { throw EngineFailure(message: reply.error ?? "No media found.") }
            return plan
        }
    }
    func inspect(url: URL, cache: URL, token: OperationToken) async throws -> CodecAvailability {
        try await withTaskCancellationHandler {
            try await perform {
                // A cancelled inspection may have waited behind extraction or
                // remux work. Drop it before entering the embedded interpreter.
                guard !token.isCancelled else { throw CancellationError() }
                let request: [String: Any] = [
                    "url": url.absoluteString, "kind": "video", "quality": 0,
                    "cache": cache.path, "operation": "inspect",
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
        // Serialize with inspections/extractions so cached files are never
        // removed while the interpreter is reading or writing them.
        try await perform {
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
