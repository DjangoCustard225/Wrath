import Foundation

/// A cancellable gate shared by network requests and the processing boundary.
public final class DownloadPauseControl: @unchecked Sendable {
    private final class Waiter: @unchecked Sendable {
        let id = UUID()
        var cancelled = false
        var continuation: CheckedContinuation<Void, Error>?
    }
    private let lock = NSLock()
    private var paused = false
    private var waiters: [UUID: Waiter] = [:]
    public var isPaused: Bool { lock.withLock { paused } }
    public init() {}
    public func setPaused(_ paused: Bool) {
        let pending: [CheckedContinuation<Void, Error>] = lock.withLock {
            self.paused = paused
            guard !paused else { return [] }
            let pending = waiters.values.compactMap { waiter in
                let continuation = waiter.continuation
                waiter.continuation = nil
                return continuation
            }
            waiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume() }
    }
    public func wait() async throws {
        let waiter = Waiter()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let result: Result<Void, Error>? = lock.withLock {
                    if waiter.cancelled { return .failure(CancellationError()) }
                    guard paused else { return .success(()) }
                    waiter.continuation = continuation
                    waiters[waiter.id] = waiter
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
            try Task.checkCancellation()
        } onCancel: {
            let continuation = self.lock.withLock {
                waiter.cancelled = true
                self.waiters.removeValue(forKey: waiter.id)
                let continuation = waiter.continuation
                waiter.continuation = nil
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
