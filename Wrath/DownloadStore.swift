import Foundation
import Observation
import UIKit
import WrathCore

@Observable @MainActor final class JobItem: Identifiable {
    var job: DownloadJob
    var progress: Double = 0
    var receivedBytes: Int64 = 0
    var expectedBytes: Int64 = 0
    var speed: Double = 0
    var eta: Double?
    var progressKnown = false
    var phase: ProcessingPhase = .preparing
    var isStreaming = false
    var preparationLabel = "Finding media"
    @ObservationIgnored var processingAttempt: UUID?
    nonisolated let id: UUID
    init(_ job: DownloadJob) {
        self.job = job
        id = job.id
    }
}

@MainActor private final class JobTransferProgress {
    private let item: JobItem
    private var bytes: [Int64]
    private var totals: [Int64]
    private var lastTime = ProcessInfo.processInfo.systemUptime
    private var meter = TransferPresentationMeter()
    init(item: JobItem, tracks: [MediaTrack]) {
        self.item = item
        bytes = Array(repeating: 0, count: tracks.count)
        // Extractor byte estimates are not confirmed HTTP transfer totals.
        totals = Array(repeating: 0, count: tracks.count)
    }
    func update(index: Int, bytes: Int64, total: Int64) {
        guard item.job.state == .downloading else { return }
        self.bytes[index] = max(self.bytes[index], bytes)
        if total > 0 { totals[index] = total }
        refresh()
    }
    func refresh() {
        guard item.job.state == .downloading else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastTime
        guard elapsed >= 0.25 else { return }
        let received = self.bytes.reduce(0, +)
        let expected = totals.reduce(0, +)
        let snapshot = meter.sample(bytes: received, total: totals.allSatisfy({ $0 > 0 }) ? expected : nil, time: now)
        item.receivedBytes = snapshot.received
        item.expectedBytes = snapshot.total ?? 0
        item.progressKnown = snapshot.fraction != nil
        item.progress = snapshot.fraction ?? 0
        item.speed = snapshot.speed
        item.eta = snapshot.eta
        lastTime = now
    }
}

@Observable @MainActor final class DownloadStore {
    var items: [JobItem] = []
    var message: String?
    var kind: MediaKind { didSet { UserDefaults.standard.set(kind.rawValue, forKey: "kind") } }
    var quality: Quality { didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") } }
    var options: DownloadOptions {
        didSet {
            if let data = try? JSONEncoder().encode(options) {
                UserDefaults.standard.set(data, forKey: "downloadOptions")
            }
        }
    }
    var isPaused = false
    var libraryBusyIDs: Set<UUID> = []
    var storage: StorageSnapshot?
    var measuringStorage = false
    var clearingCache = false
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var token: OperationToken?
    @ObservationIgnored private var transfers: [MediaTransfer] = []
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private let persistence = DispatchQueue(label: "Wrath.Persistence", qos: .utility)
    let documents: URL
    private let support: URL
    private let queueFile: URL
    private let temporary: URL
    private let files: LibraryFiles
    @ObservationIgnored private var probingIDs: Set<UUID> = []
    @ObservationIgnored private var storageRefreshPending = false
    var activeCount: Int { items.filter { $0.job.state.isActive || $0.job.state == .queued }.count }
    var library: [JobItem] { items.filter { $0.job.state == .completed }.reversed() }
    var queue: [JobItem] { items.filter { $0.job.state != .completed } }

    init() {
        let fm = FileManager.default
        documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(
            "Wrath", isDirectory: true)
        temporary = support.appendingPathComponent("Working", isDirectory: true)
        queueFile = support.appendingPathComponent("queue.json")
        files = LibraryFiles(documents: documents, support: support)
        kind = MediaKind(rawValue: UserDefaults.standard.string(forKey: "kind") ?? "video") ?? .video
        quality = Quality(rawValue: UserDefaults.standard.object(forKey: "quality") as? Int ?? 1080) ?? .fullHD
        var restoredOptions =
            UserDefaults.standard.data(forKey: "downloadOptions").flatMap {
                try? JSONDecoder().decode(DownloadOptions.self, from: $0)
            } ?? DownloadOptions()
        // Enabled SponsorBlock preferences now always remove segments.
        if restoredOptions.sponsorMode != .off { restoredOptions.sponsorMode = .remove }
        options = restoredOptions
        do {
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            try fm.createDirectory(at: documents, withIntermediateDirectories: true)
            if fm.fileExists(atPath: queueFile.path) {
                var jobs = try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: queueFile))
                for i in jobs.indices {
                    if jobs[i].state.isActive {
                        jobs[i].state = .failed
                        jobs[i].error = "Interrupted when the app closed. Retry to refresh the media link."
                    }
                    if jobs[i].state == .completed, let name = jobs[i].filename,
                        name != (name as NSString).lastPathComponent
                            || !fm.fileExists(atPath: documents.appendingPathComponent(name).path)
                    {
                        jobs[i].state = .failed
                        jobs[i].filename = nil
                        jobs[i].error = "The saved file was moved or deleted."
                    }
                }
                items = jobs.map(JobItem.init)
            }
            if fm.fileExists(atPath: temporary.path) { try fm.removeItem(at: temporary) }
            try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        } catch { message = "Could not restore downloads: \(error.localizedDescription)" }
        // Restored queued work waits for an explicit resume to avoid surprising transfers.
        isPaused = items.contains { $0.job.state == .queued }
    }
    func add(_ url: URL, availability: CodecAvailability? = nil) {
        let captured = (availability?.optionsForDownload(options, kind: kind, quality: quality) ?? options).forSource(
            url)
        guard
            !items.contains(where: {
                $0.job.sourceURL == url && ($0.job.state.isActive || $0.job.state == .queued) && $0.job.kind == kind
                    && $0.job.quality == quality && $0.job.effectiveOptions == captured
            })
        else {
            message = "This link is already in the queue."
            return
        }
        var job = DownloadJob(url: url, kind: kind, quality: quality, options: captured)
        job.codecAvailability = availability
        items.append(JobItem(job))
        save()
        startNext()
    }
    func retry(_ item: JobItem) {
        guard !item.job.state.isActive else { return }
        item.job.state = .queued
        item.job.error = nil
        item.job.warning = nil
        item.progress = 0
        item.progressKnown = false
        item.speed = 0
        item.eta = nil
        save()
        startNext()
    }
    func updateOptions(_ item: JobItem, options: DownloadOptions) {
        guard [.queued, .failed, .cancelled].contains(item.job.state) else { return }
        var captured =
            (item.job.codecAvailability?.optionsForDownload(options, kind: item.job.kind, quality: item.job.quality)
            ?? options).forSource(item.job.sourceURL)
        if captured.sponsorMode != .off { captured.sponsorMode = .remove }
        item.job.options = captured
        item.job.sponsorSegmentsFound = nil
        save()
    }
    func updateAvailability(_ item: JobItem, availability: CodecAvailability) {
        guard [.queued, .failed, .cancelled].contains(item.job.state) else { return }
        item.job.codecAvailability = availability
        updateSelection(item, kind: item.job.kind, quality: item.job.quality)
    }
    func updateSelection(_ item: JobItem, kind: MediaKind, quality: Quality) {
        guard [.queued, .failed, .cancelled].contains(item.job.state),
            let availability = item.job.codecAvailability, let firstKind = availability.mediaKinds.first
        else { return }
        item.job.kind = availability.mediaKinds.contains(kind) ? kind : firstKind
        item.job.quality = item.job.kind == .video ? availability.resolvingQuality(quality) : .best
        updateOptions(item, options: item.job.effectiveOptions)
    }
    func toggleQueue() {
        isPaused.toggle()
        if !isPaused { startNext() }
    }
    func cancel(_ item: JobItem) {
        if item.job.state.isActive {
            token?.cancel()
            for transfer in transfers { transfer.cancel() }
            runner?.cancel()
        }
        item.job.state = .cancelled
        item.speed = 0
        save()
    }
    func remove(_ item: JobItem) {
        guard !item.job.state.isActive else {
            cancel(item)
            return
        }
        if item.job.state == .completed {
            Task { _ = await deleteFiles([item.id]) }
            return
        }
        do {
            if let url = fileURL(item), FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            items.removeAll { $0.id == item.id }
            save()
        } catch { message = "Could not delete the file: \(error.localizedDescription)" }
    }
    func rename(_ item: JobItem, stem: String) async -> String? {
        guard item.job.state == .completed, let original = item.job.filename,
            !libraryBusyIDs.contains(item.id)
        else { return "This file is busy. Try again shortly." }
        libraryBusyIDs.insert(item.id)
        defer { libraryBusyIDs.remove(item.id) }
        do {
            let name = try await files.rename(original, stem: stem)
            item.job.filename = name
            item.job.title = (name as NSString).deletingPathExtension
            save()
            Task { await refreshStorage() }
            return nil
        } catch { return error.localizedDescription }
    }
    func deleteFiles(_ ids: Set<UUID>) async -> Set<UUID> {
        let candidates = library.filter {
            ids.contains($0.id) && !libraryBusyIDs.contains($0.id) && $0.job.filename != nil
        }
        let busy = Set(candidates.map(\.id))
        libraryBusyIDs.formUnion(busy)
        defer { libraryBusyIDs.subtract(busy) }
        let report = await files.delete(candidates.compactMap(\.job.filename))
        let removed = Set(candidates.filter { report.deleted.contains($0.job.filename!) }.map(\.id))
        items.removeAll { removed.contains($0.id) }
        save()
        if !report.failures.isEmpty {
            message =
                "\(removed.count) deleted; \(report.failures.count) could not be deleted.\n"
                + report.failures.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
        Task { await refreshStorage() }
        return removed
    }
    func refreshStorage() async {
        guard !measuringStorage else {
            storageRefreshPending = true
            return
        }
        measuringStorage = true
        defer { measuringStorage = false }
        repeat {
            storageRefreshPending = false
            let thumbnailBytes = await ThumbnailCache.shared.diskBytes
            storage = await files.storage(thumbnailBytes: thumbnailBytes)
        } while storageRefreshPending
    }
    func clearCaches() async {
        guard !clearingCache else { return }
        clearingCache = true
        defer { clearingCache = false }
        await ThumbnailCache.shared.clear()
        do { try await MediaEngine.shared.clearExtractorCache(in: support) } catch {
            message = "Could not clear the extractor cache: \(error.localizedDescription)"
        }
        await refreshStorage()
    }
    func loadFileDetails(_ item: JobItem) async {
        guard item.job.state == .completed, item.job.savedMediaInfo == nil,
            let file = fileURL(item), !probingIDs.contains(item.id)
        else { return }
        probingIDs.insert(item.id)
        defer { probingIDs.remove(item.id) }
        if let info = await MediaEngine.shared.probe(file), item.job.filename == file.lastPathComponent,
            item.job.state == .completed, items.contains(where: { $0.id == item.id })
        {
            item.job.savedMediaInfo = info
            save()
        }
    }
    func clearFinishedQueue() {
        items.removeAll { [.cancelled, .failed].contains($0.job.state) }
        save()
    }
    func fileURL(_ item: JobItem) -> URL? {
        guard let name = item.job.filename, name == (name as NSString).lastPathComponent else { return nil }
        return documents.appendingPathComponent(name)
    }
    private func save() {
        let snapshot = items.map(\.job)
        let file = queueFile
        persistence.async { [weak self] in
            do { try JSONEncoder().encode(snapshot).write(to: file, options: .atomic) } catch {
                Task { @MainActor in self?.message = "Could not save the queue: \(error.localizedDescription)" }
            }
        }
    }
    private func startNext() {
        guard runner == nil, !isPaused, let item = items.first(where: { $0.job.state == .queued }) else { return }
        let token = OperationToken()
        self.token = token
        runner = Task { await run(item, token: token) }
    }
    private func run(_ item: JobItem, token: OperationToken) async {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish media download") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPaused = true
                self.token?.cancel()
                for transfer in self.transfers { transfer.cancel() }
                self.runner?.cancel()
                if item.job.state.isActive {
                    item.job.state = .failed
                    item.job.error = "iOS ended background time. Open Wrath and retry to continue."
                    self.save()
                }
                if self.backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(self.backgroundTask)
                    self.backgroundTask = .invalid
                }
            }
        }
        let directory = temporary.appendingPathComponent(item.id.uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
            transfers = []
            self.token = nil
            runner = nil
            save()
            startNext()
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            item.job.state = .resolving
            item.preparationLabel = "Finding media"
            save()
            let plan = try await MediaEngine.shared.extract(
                job: item.job, cache: support.appendingPathComponent("ExtractorCache"), token: token)
            try Task.checkCancellation()
            item.job.title = plan.title
            item.job.author = plan.author
            item.job.thumbnail = plan.thumbnail
            item.job.sponsorSegmentsFound = plan.sponsorSegments?.count ?? 0
            item.job.warning = plan.subtitleWarning
            let options = item.job.effectiveOptions
            var cover: URL?
            if options.embedThumbnail {
                item.preparationLabel = "Preparing thumbnail"
                do {
                    cover = try await EmbeddedArtwork.shared.prepare(
                        url: plan.thumbnail, destination: directory.appendingPathComponent("cover.jpg"))
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    item.job.warning = DownloadWarnings.appending(ArtworkRecovery.warning, to: item.job.warning)
                }
            }
            try Task.checkCancellation()
            item.job.state = .downloading
            item.isStreaming = plan.tracks.contains { $0.streaming }
            save()
            var inputs: [URL] = []
            var headers: [String] = []
            let progress = JobTransferProgress(item: item, tracks: plan.tracks)
            // Let speed and ETA decay during a network stall, even when the
            // transport has no new bytes to report. UI updates stay at 4 Hz.
            let ticker = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                    progress.refresh()
                }
            }
            defer { ticker.cancel() }
            let directCount = plan.tracks.filter { !$0.streaming }.count
            var downloads: [(Int, MediaTrack, MediaTransfer)] = []
            for (index, track) in plan.tracks.enumerated() {
                try Task.checkCancellation()
                if track.streaming {
                    inputs.append(track.url)
                    headers.append(
                        track.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined())
                    continue
                }
                let destination = directory.appendingPathComponent("track-\(index)")
                let connections = directCount == 1 ? 4 : (track.role == "audio" ? 1 : 3)
                let transfer = MediaTransfer(destination: destination, connections: connections) { bytes, total, _ in
                    Task { @MainActor in progress.update(index: index, bytes: bytes, total: total) }
                }
                transfers.append(transfer)
                downloads.append((index, track, transfer))
                inputs.append(destination)
                headers.append("")
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (_, track, transfer) in downloads {
                    group.addTask { _ = try await transfer.download(track) }
                }
                do { for try await _ in group {} } catch {
                    group.cancelAll()
                    throw error
                }
            }
            try Task.checkCancellation()
            item.job.state = .processing
            item.progress = 0
            item.progressKnown = false
            item.phase = .preparing
            item.speed = 0
            item.eta = nil
            save()
            let processed = try await ArtworkRecovery.finish(cover: cover) { artwork in
                let captions = try await SubtitleRecovery.finish(subtitle: plan.subtitle) { subtitle in
                    let attempt = UUID()
                    item.processingAttempt = attempt
                    defer { if item.processingAttempt == attempt { item.processingAttempt = nil } }
                    return try await MediaEngine.shared.remux(
                        inputs: inputs, headers: headers, output: directory.appendingPathComponent("finished"),
                        audioOnly: item.job.kind == .audio, token: token,
                        cover: artwork, segments: plan.sponsorSegments ?? [], sponsorMode: options.sponsorMode,
                        subtitle: subtitle
                    ) { [weak item] phase, progress in
                        Task { @MainActor in
                            if let item, item.job.state == .processing, item.processingAttempt == attempt {
                                let samePhase = item.phase == phase
                                item.phase = phase
                                item.progressKnown = progress != nil
                                item.progress = progress.map { samePhase ? max(item.progress, $0) : $0 } ?? 0
                            }
                        }
                    }
                }
                if let warning = captions.warning {
                    item.job.warning = DownloadWarnings.appending(warning, to: item.job.warning)
                }
                return captions.url
            }
            if let warning = processed.warning {
                item.job.warning = DownloadWarnings.appending(warning, to: item.job.warning)
            }
            let staged = processed.url
            item.phase = .saving
            item.progressKnown = false
            item.job.savedMediaInfo = await MediaEngine.shared.probe(staged, token: token)
            try Task.checkCancellation()
            let size = try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw EngineFailure(message: "The processed file is empty.") }
            let filename = try LibraryFiles.publish(
                staged, to: documents, title: plan.title, reservedNames: Set(items.compactMap(\.job.filename)))
            item.job.filename = filename
            item.job.bytes = Int64(size)
            item.job.progress = 1
            item.job.completed = Date()
            item.job.state = .completed
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            if item.job.state.isActive {
                item.job.state = Task.isCancelled ? .cancelled : .failed
                item.job.error = Task.isCancelled ? nil : error.localizedDescription
                item.speed = 0
            }
        }
    }
}
