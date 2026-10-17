import Foundation
import Observation

/// Owns one inspection independently of the loading/result views that display it.
@Observable @MainActor public final class LinkInspector {
    public private(set) var availability: CodecAvailability?
    public private(set) var sourceURL: URL?
    public private(set) var loading = false
    public private(set) var error: String?
    public var revision = 0

    private struct Request: Equatable {
        let url: URL?
        let revision: Int
    }
    @ObservationIgnored private var lastRequest: Request?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var operation: Task<CodecAvailability, Error>?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private let load: @Sendable (URL) async throws -> CodecAvailability

    public init(
        debounce: Duration = .milliseconds(450), timeout: Duration = .seconds(30),
        load: @escaping @Sendable (URL) async throws -> CodecAvailability
    ) {
        self.debounce = debounce
        self.timeout = timeout
        self.load = load
    }

    public func inspect(_ url: URL?) async {
        let key = Request(url: url, revision: revision)
        // A result/error must survive view reappearance. Only a new URL or an
        // explicit Retry may clear it and start another extraction.
        if lastRequest == key,
            availability != nil || error != nil || (loading && operation?.isCancelled == false)
        {
            return
        }
        operation?.cancel()
        let request = UUID()
        requestID = request
        lastRequest = key
        availability = nil
        error = nil
        sourceURL = url
        loading = url != nil
        guard let url else {
            operation = nil
            return
        }

        let load = load
        let debounce = debounce
        let work = Task {
            try await Task.sleep(for: debounce)
            try Task.checkCancellation()
            return try await load(url)
        }
        operation = work
        // A noncooperative socket/engine must never leave the UI spinning
        // indefinitely. Late results are discarded after this deadline.
        let deadline = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.requestID == request, self.loading else { return }
            self.error = "Checking this link took too long. Retry to read its available formats."
            self.loading = false
            work.cancel()
        }
        defer {
            deadline.cancel()
            if requestID == request {
                loading = false
                operation = nil
            }
        }
        await withTaskCancellationHandler {
            do {
                let result = try await work.value
                try Task.checkCancellation()
                guard requestID == request, loading else { return }
                availability = result
            } catch {
                guard requestID == request, loading else { return }
                if work.isCancelled || Task.isCancelled {
                    lastRequest = nil
                } else {
                    self.error = error.localizedDescription
                }
            }
        } onCancel: {
            work.cancel()
        }
    }
}
