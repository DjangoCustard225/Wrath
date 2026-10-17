import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public enum MediaTransferError: LocalizedError, Sendable {
    case invalidResponse, invalidRange, changedSource, emptyFile
    case http(Int)
    case alreadyStarted
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "The server returned an invalid download response."
        case .invalidRange: "The server returned an incorrect media segment. Retry to refresh the link."
        case .changedSource: "The media changed during download. Retry to refresh the link."
        case .emptyFile: "The server returned an empty file."
        case .http(let code): "The server refused the download (HTTP \(code)). Retry to refresh the link."
        case .alreadyStarted: "This transfer has already started."
        }
    }
}

private struct ByteRange: Sendable {
    let start: Int64
    let end: Int64
    var count: Int64 { end - start + 1 }
    var header: String { "bytes=\(start)-\(end)" }
}

private struct ContentRange: Sendable {
    let range: ByteRange
    let total: Int64
    init?(_ value: String?) {
        guard let value else { return nil }
        let parts = value.split(separator: " ")
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let length = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        guard length.count == 2, let total = Int64(length[1]), total > 0 else { return nil }
        let bounds = length[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
            start >= 0, end >= start, end < total
        else { return nil }
        self.range = ByteRange(start: start, end: end)
        self.total = total
    }
}

private final class RequestControl: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func attach(_ task: URLSessionTask) {
        let shouldCancel = lock.withLock {
            self.task = task
            return cancelled
        }
        if shouldCancel { task.cancel() }
    }
    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return task
        }
        task?.cancel()
    }
}

private struct DownloadedPart: Sendable {
    let file: URL
    let response: HTTPURLResponse
    let count: Int64
}

private final class DownloadTransport: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private final class Pending {
        let continuation: CheckedContinuation<DownloadedPart, Error>
        let progress: @Sendable (Int64, HTTPURLResponse?) -> Void
        var result: Result<DownloadedPart, Error>?
        init(
            _ continuation: CheckedContinuation<DownloadedPart, Error>,
            _ progress: @escaping @Sendable (Int64, HTTPURLResponse?) -> Void
        ) {
            self.continuation = continuation
            self.progress = progress
        }
    }
    private let directory: URL
    private let cookies: [MediaCookie]
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var cancelled = false
    private var session: URLSession!
    init(directory: URL, connections: Int, track: MediaTrack) {
        self.directory = directory
        cookies = track.cookies ?? []
        super.init()
        let config = URLSessionConfiguration.ephemeral
        // Explicit matching keeps cookie scope consistent across platforms and
        // redirects, without adding extraction cookies to shared storage.
        if !cookies.isEmpty {
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
        }
        config.httpMaximumConnectionsPerHost = connections
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }
    func fetch(_ request: URLRequest, progress: @escaping @Sendable (Int64, HTTPURLResponse?) -> Void) async throws
        -> DownloadedPart
    {
        let request = applyingCookies(to: request)
        let control = RequestControl()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request)
                task.priority = URLSessionTask.highPriority
                let registered = lock.withLock {
                    guard !cancelled else { return false }
                    pending[task.taskIdentifier] = Pending(continuation, progress)
                    return true
                }
                guard registered else {
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                control.attach(task)
                task.resume()
            }
        } onCancel: {
            control.cancel()
        }
    }
    private func applyingCookies(to original: URLRequest) -> URLRequest {
        guard !cookies.isEmpty else { return original }
        var request = original
        request.httpShouldHandleCookies = false
        guard let url = request.url, let host = url.host?.lowercased() else {
            request.setValue(nil, forHTTPHeaderField: "Cookie")
            return request
        }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
        let requestPath = path.isEmpty ? "/" : path
        let now = Date().timeIntervalSince1970
        let matching = cookies.compactMap { cookie -> HTTPCookie? in
            let domain = cookie.domain.lowercased().drop(while: { $0 == "." })
            guard !domain.isEmpty,
                host == domain || (!cookie.hostOnly && host.hasSuffix("." + domain)),
                !cookie.secure || url.scheme?.lowercased() == "https",
                cookie.expires.map({ $0.isFinite && $0 > now }) ?? true
            else { return nil }
            let cookiePath = cookie.path.hasPrefix("/") ? cookie.path : "/"
            guard
                requestPath == cookiePath
                    || (requestPath.hasPrefix(cookiePath)
                        && (cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).first == "/")),
                !cookie.name.isEmpty,
                cookie.name.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 59 && $0 != 61 }),
                cookie.value.utf8.allSatisfy({ $0 >= 32 && $0 != 127 && $0 != 59 })
            else { return nil }
            return HTTPCookie(properties: [
                .name: cookie.name, .value: cookie.value, .domain: cookie.domain, .path: cookiePath,
            ])
        }
        request.setValue(
            HTTPCookie.requestHeaderFields(with: matching)["Cookie"], forHTTPHeaderField: "Cookie")
        return request
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(applyingCookies(to: request))
    }
    func cancel() {
        lock.withLock { cancelled = true }
        session.invalidateAndCancel()
    }
    func finish() { session.finishTasksAndInvalidate() }
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let callback = lock.withLock { pending[downloadTask.taskIdentifier]?.progress }
        callback?(totalBytesWritten, downloadTask.response as? HTTPURLResponse)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let entry = lock.withLock { pending[downloadTask.taskIdentifier] }
        guard let entry else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw MediaTransferError.invalidResponse
            }
            guard response.statusCode == 200 || response.statusCode == 206 else {
                throw MediaTransferError.http(response.statusCode)
            }
            let count = Int64(try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard count > 0 else { throw MediaTransferError.emptyFile }
            let file = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: file)
            entry.result = .success(DownloadedPart(file: file, response: response, count: count))
        } catch { entry.result = .failure(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error {
            if case .success(let part) = entry.result { try? FileManager.default.removeItem(at: part.file) }
            entry.continuation.resume(throwing: error)
        } else {
            entry.continuation.resume(with: entry.result ?? .failure(MediaTransferError.invalidResponse))
        }
    }
}

private final class TransferMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [Int64: Int64] = [:]
    private var total: Int64 = 0
    private var lastTime = ProcessInfo.processInfo.systemUptime
    private var lastBytes: Int64 = 0
    private let callback: @Sendable (Int64, Int64, Double) -> Void
    init(_ callback: @escaping @Sendable (Int64, Int64, Double) -> Void) { self.callback = callback }
    func update(_ key: Int64, count: Int64, total: Int64? = nil, force: Bool = false) {
        let report: (Int64, Int64, Double)? = lock.withLock {
            received[key] = max(received[key] ?? 0, count)
            if let total, total > 0 { self.total = total }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - lastTime
            guard force || elapsed >= 0.25 else { return nil }
            let bytes = received.values.reduce(0, +)
            let speed = elapsed > 0 ? Double(max(0, bytes - lastBytes)) / elapsed : 0
            lastTime = now
            lastBytes = bytes
            return (bytes, self.total, speed)
        }
        if let report { callback(report.0, report.1, report.2) }
    }
}

private actor RangeAllocator {
    private var next: Int64
    private let total: Int64
    private let size: Int64
    init(start: Int64, total: Int64, size: Int64) {
        next = start
        self.total = total
        self.size = size
    }
    func claim() -> ByteRange? {
        guard next < total else { return nil }
        let range = ByteRange(start: next, end: next + min(size, total - next) - 1)
        next = range.end + 1
        return range
    }
}

private final class SegmentWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileHandle
    init(destination: URL, size: Int64) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        file = try FileHandle(forWritingTo: destination)
        try file.truncate(atOffset: UInt64(size))
    }
    func commit(_ part: DownloadedPart, at offset: Int64) throws {
        try lock.withLock {
            let input = try FileHandle(forReadingFrom: part.file)
            defer { try? input.close() }
            try file.seek(toOffset: UInt64(offset))
            while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                try file.write(contentsOf: data)
            }
            try FileManager.default.removeItem(at: part.file)
        }
    }
    func close() { lock.withLock { try? file.close() } }
}

/// Disk-backed HTTP transfer with bounded, validated byte ranges and a shared connection pool.
public final class MediaTransfer: @unchecked Sendable {
    private let destination: URL
    private let connections: Int
    private let maximumChunkSize: Int64
    private let progress: @Sendable (Int64, Int64, Double) -> Void
    private let lock = NSLock()
    private var transport: DownloadTransport?
    private var cancelled = false
    private var started = false
    public init(
        destination: URL, connections: Int = 4, chunkSize: Int64 = 8 * 1024 * 1024,
        progress: @escaping @Sendable (Int64, Int64, Double) -> Void
    ) {
        self.destination = destination
        self.connections = min(4, max(1, connections))
        maximumChunkSize = min(8 * 1024 * 1024, max(64 * 1024, chunkSize))
        self.progress = progress
    }
    public func cancel() {
        let transport = lock.withLock {
            cancelled = true
            return transport
        }
        transport?.cancel()
    }
    public func download(_ track: MediaTrack) async throws -> URL {
        let allowed = lock.withLock {
            if started { return false }
            started = true
            return true
        }
        guard allowed else { throw MediaTransferError.alreadyStarted }
        return try await withTaskCancellationHandler {
            try await run(track)
        } onCancel: {
            self.cancel()
        }
    }
    private func run(_ track: MediaTrack) async throws -> URL {
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        let directory = destination.deletingLastPathComponent().appendingPathComponent(
            ".parts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = DownloadTransport(directory: directory, connections: connections, track: track)
        let alreadyCancelled = lock.withLock {
            self.transport = transport
            return cancelled
        }
        if alreadyCancelled {
            transport.cancel()
            throw CancellationError()
        }
        defer { transport.finish() }
        let meter = TransferMeter(progress)
        let preferred = track.chunkSize.flatMap { $0 > 0 ? $0 : nil } ?? maximumChunkSize
        let chunk = min(maximumChunkSize, preferred)
        let initial = ByteRange(start: 0, end: min(chunk, 1024 * 1024) - 1)
        let first = try await fetch(track, range: initial, validator: nil, transport: transport, meter: meter)
        if first.response.statusCode == 200 {
            try validateComplete(first)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: first.file, to: destination)
            meter.update(0, count: first.count, total: first.count, force: true)
            return destination
        }
        guard let content = ContentRange(first.response.value(forHTTPHeaderField: "Content-Range")) else {
            throw MediaTransferError.invalidRange
        }
        try validate(first, requested: initial, total: content.total, etag: nil)
        let etag = first.response.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
        let validator = etag ?? first.response.value(forHTTPHeaderField: "Last-Modified")
        let writer = try SegmentWriter(destination: destination, size: content.total)
        do {
            try writer.commit(first, at: 0)
            meter.update(0, count: first.count, total: content.total)
            let allocator = RangeAllocator(start: content.range.end + 1, total: content.total, size: chunk)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<connections {
                    group.addTask { [self] in
                        while let range = await allocator.claim() {
                            try Task.checkCancellation()
                            let part = try await fetch(
                                track, range: range, validator: validator, transport: transport, meter: meter)
                            try validate(part, requested: range, total: content.total, etag: etag)
                            try writer.commit(part, at: range.start)
                            meter.update(range.start, count: range.count)
                        }
                    }
                }
                do { for try await _ in group {} } catch {
                    group.cancelAll()
                    throw error
                }
            }
            try Task.checkCancellation()
            writer.close()
            meter.update(0, count: first.count, total: content.total, force: true)
            return destination
        } catch {
            writer.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    private func fetch(
        _ track: MediaTrack, range: ByteRange, validator: String?, transport: DownloadTransport, meter: TransferMeter
    ) async throws -> DownloadedPart {
        var request = URLRequest(url: track.url)
        for (name, value) in track.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(range.header, forHTTPHeaderField: "Range")
        if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        for attempt in 0...2 {
            try Task.checkCancellation()
            do {
                return try await transport.fetch(request) { bytes, response in
                    let total = response.flatMap {
                        ContentRange($0.value(forHTTPHeaderField: "Content-Range"))?.total
                            ?? ($0.statusCode == 200 && $0.expectedContentLength > 0 ? $0.expectedContentLength : nil)
                    }
                    meter.update(range.start, count: bytes, total: total)
                }
            } catch {
                let transient: Bool
                if let error = error as? URLError {
                    transient = [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code)
                } else if case MediaTransferError.http(let code) = error {
                    transient = (500...599).contains(code)
                } else {
                    transient = false
                }
                guard transient, attempt < 2 else { throw error }
                try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        throw MediaTransferError.invalidResponse
    }
    private func validateComplete(_ part: DownloadedPart) throws {
        let expected = part.response.expectedContentLength
        if expected > 0 && expected != part.count { throw MediaTransferError.invalidResponse }
    }
    private func validate(_ part: DownloadedPart, requested: ByteRange, total: Int64, etag: String?) throws {
        guard part.response.statusCode == 206,
            let content = ContentRange(part.response.value(forHTTPHeaderField: "Content-Range")),
            content.range.start == requested.start, content.range.end == min(requested.end, total - 1),
            content.total == total, part.count == content.range.count
        else { throw MediaTransferError.invalidRange }
        if let encoding = part.response.value(forHTTPHeaderField: "Content-Encoding"),
            encoding.lowercased() != "identity"
        {
            throw MediaTransferError.invalidRange
        }
        if let etag, let current = part.response.value(forHTTPHeaderField: "ETag"), etag != current {
            throw MediaTransferError.changedSource
        }
    }
}
