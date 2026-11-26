import Foundation
import Observation
import UIKit
import WrathCore

@MainActor private final class JobTransferProgress {
    private let item: JobItem
    private var bytes: [Int64]
    private var totals: [Int64]
    private var lastTime = ProcessInfo.processInfo.systemUptime
    private var meter = TransferPresentationMeter()
    init(item: JobItem, tracks: [MediaTrack]) {
        self.item = item
        bytes = Array(repeating: 0, count: tracks.count)
        // Use declared sizes until upstream supplies updated transfer totals.
        totals = tracks.map { max(0, $0.bytes ?? 0) }
    }
    private var upstreamSpeed: Double?
    private var upstreamETA: Double?
    private var lastProgressTime = ProcessInfo.processInfo.systemUptime
    func update(index: Int, bytes: Int64, total: Int64, speed: Double?, eta: Double?) {
        guard item.job.state == .downloading, !item.isPaused else { return }
        guard self.bytes.indices.contains(index) else { return }
        self.bytes[index] = max(self.bytes[index], bytes)
        upstreamSpeed = speed
        upstreamETA = eta
        lastProgressTime = ProcessInfo.processInfo.systemUptime
        if total > 0 { totals[index] = total }
        refresh()
    }
    func refresh() {
        guard item.job.state == .downloading else { return }
        if item.isPaused {
            meter = TransferPresentationMeter()
            lastTime = ProcessInfo.processInfo.systemUptime
            return
        }
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
        let fresh = now - lastProgressTime < 2
        item.speed = fresh ? (upstreamSpeed ?? snapshot.speed) : snapshot.speed
        item.eta = fresh ? (upstreamETA ?? snapshot.eta) : snapshot.eta
        lastTime = now
    }
}

@Observable @MainActor final class DownloadStore {
    var items: [JobItem] = []
    var message: String?
    /// The failed social link, offered for account reconnect only on access errors.
    var failedSocialLink: URL?
    var kind: MediaKind { didSet { UserDefaults.standard.set(kind.rawValue, forKey: PreferenceKey.mediaKind) } }
    var quality: Quality { didSet { UserDefaults.standard.set(quality.rawValue, forKey: PreferenceKey.quality) } }
    var options: DownloadOptions {
        didSet {
            if let data = try? JSONEncoder().encode(options) {
                UserDefaults.standard.set(data, forKey: PreferenceKey.downloadOptions)
            }
        }
    }
    var isDownloadOccupied = false
    var libraryBusyIDs: Set<UUID> = []
    var storage: StorageSnapshot?
    var measuringStorage = false
    var clearingCache = false
    /// A short confirmation, such as after saving to Photos.
    var toast: String?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var token: OperationToken?
    @ObservationIgnored private var pauseControl = DownloadPauseControl()
    @ObservationIgnored private var backgroundSession: DownloadBackgroundSession?
    @ObservationIgnored private var activeTransfer: JobTransferProgress?
    @ObservationIgnored private let liveActivity = DownloadLiveActivityController()
    @ObservationIgnored private let persistence = DispatchQueue(label: "Wrath.Persistence", qos: .utility)
    let documents: URL
    private let support: URL
    private let historyFile: URL
    private let temporary: URL
    private let files: LibraryFiles
    @ObservationIgnored private var probingIDs: Set<UUID> = []
    @ObservationIgnored private var storageRefreshPending = false
    static let busyMessage = "A download is already in progress. Wait for it to finish before adding another link."
    var library: [JobItem] { items.filter { $0.job.state == .completed } }
    /// The one download that is resolving, downloading or processing, if any.
    var activeItem: JobItem? { items.first { $0.job.state.isActive } }
    var canAddDownload: Bool { !isDownloadOccupied && !clearingCache }

    init() {
        let fm = FileManager.default
        documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(
            "Wrath", isDirectory: true)
        temporary = support.appendingPathComponent("Working", isDirectory: true)
        historyFile = support.appendingPathComponent("queue.json")
        files = LibraryFiles(documents: documents, support: support)
        kind = MediaKind(rawValue: UserDefaults.standard.string(forKey: PreferenceKey.mediaKind) ?? "video") ?? .video
        quality =
            Quality(rawValue: UserDefaults.standard.object(forKey: PreferenceKey.quality) as? Int ?? 1080) ?? .fullHD
        var restoredOptions =
            UserDefaults.standard.data(forKey: PreferenceKey.downloadOptions).flatMap {
                try? JSONDecoder().decode(DownloadOptions.self, from: $0)
            } ?? DownloadOptions()
        // Enabled SponsorBlock preferences now always remove segments.
        if restoredOptions.sponsorMode != .off { restoredOptions.sponsorMode = .remove }
        options = restoredOptions
        do {
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            try fm.createDirectory(at: documents, withIntermediateDirectories: true)
            if fm.fileExists(atPath: historyFile.path) {
                let jobs = try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: historyFile))
                // Discard legacy pending/failed records and missing saved files.
                items = jobs.filter { job in
                    guard job.state == .completed else { return false }
                    guard let name = job.filename else { return true }
                    return name == (name as NSString).lastPathComponent
                        && fm.fileExists(atPath: documents.appendingPathComponent(name).path)
                }.map(JobItem.init)
                if items.count != jobs.count { save() }
            }
            if fm.fileExists(atPath: temporary.path) { try fm.removeItem(at: temporary) }
            try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        } catch { message = "Could not restore downloads: \(error.localizedDescription)" }
    }
    @discardableResult func add(_ url: URL, availability: CodecAvailability? = nil) -> Bool {
        guard canAddDownload else {
            if clearingCache {
                message = "Wrath is clearing its cache. Try adding the link again shortly."
            } else {
                message = Self.busyMessage
            }
            return false
        }
        failedSocialLink = nil
        let captured = (availability?.optionsForDownload(options, kind: kind, quality: quality) ?? options).forSource(
            url)
        var job = DownloadJob(
            url: url, kind: availability?.gallery != nil ? .images : kind, quality: quality, options: captured)
        job.codecAvailability = availability
        job.state = .resolving
        let item = JobItem(job)
        items.append(item)
        isDownloadOccupied = true
        save()
        Haptics.started()
        DownloadNotifier.requestPermissionIfNeeded()
        start(item)
        return true
    }
    func toggleDownloadPause(_ item: JobItem) {
        guard
            item.job.state == .downloading
                || (item.job.state == .processing && item.isStreaming && item.phase == .copying)
        else { return }
        item.isPaused.toggle()
        item.speed = 0
        item.eta = nil
        pauseControl.setPaused(item.isPaused)
        token?.setPaused(item.isPaused)
    }
    func cancel(_ item: JobItem) {
        guard item.job.state.isActive else { return }
        token?.cancel()
        runner?.cancel()
        backgroundSession?.finish(success: false)
        item.job.state = .cancelled
        item.isPaused = false
        item.speed = 0
        save()
    }
    func rename(_ item: JobItem, stem: String) async -> String? {
        guard item.job.state == .completed, let original = item.job.filename,
            !libraryBusyIDs.contains(item.id)
        else { return "This file is busy. Try again shortly." }
        libraryBusyIDs.insert(item.id)
        defer { libraryBusyIDs.remove(item.id) }
        do {
            let name = try await files.rename(original, stem: stem, isGallery: item.job.kind == .images)
            item.job.filename = name
            item.job.title = item.job.kind == .images ? name : (name as NSString).deletingPathExtension
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
        let report = await files.delete(
            candidates.compactMap(\.job.filename),
            galleries: Set(candidates.filter { $0.job.kind == .images }.compactMap(\.job.filename)))
        let removed = Set(candidates.filter { $0.job.filename.map(report.deleted.contains) == true }.map(\.id))
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
        guard item.job.kind != .images, item.job.state == .completed, item.job.savedMediaInfo == nil,
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
    /// The saved files behind a library item: the media file, or every photo in a gallery.
    func savedURLs(_ item: JobItem) -> [URL] {
        item.job.kind == .images ? item.galleryURLs : fileURL(item).map { [$0] } ?? []
    }

    func saveToPhotos(_ items: [JobItem]) async {
        await saveToPhotos(urls: items.flatMap(savedURLs))
    }

    func saveToPhotos(urls: [URL]) async {
        do {
            let count = try await PhotoLibrarySaver.save(urls)
            toast = count == 1 ? "Saved to Photos" : "Saved \(count) items to Photos"
            Haptics.success()
        } catch {
            message = error.localizedDescription
            Haptics.failure()
        }
    }

    func fileURL(_ item: JobItem) -> URL? {
        guard let name = item.job.filename, name == (name as NSString).lastPathComponent else { return nil }
        return documents.appendingPathComponent(name)
    }
    private func save() {
        let snapshot = items.map(\.job)
        let file = historyFile
        persistence.async { [weak self] in
            do { try JSONEncoder().encode(snapshot).write(to: file, options: .atomic) } catch {
                Task { @MainActor in self?.message = "Could not save download history: \(error.localizedDescription)" }
            }
        }
    }
    private func start(_ item: JobItem) {
        guard runner == nil else { return }
        let token = OperationToken()
        pauseControl = DownloadPauseControl()
        self.token = token
        runner = Task { await run(item, token: token) }
    }
    func redactSystemProgress() { backgroundSession?.redactMediaDetails() }
    // MARK: - Running a download

    private func run(_ item: JobItem, token: OperationToken) async {
        let background = DownloadBackgroundSession()
        backgroundSession = background
        let directory = temporary.appendingPathComponent(item.id.uuidString, isDirectory: true)
        do {
            let notice = try await background.begin(id: item.id, title: item.job.title) { [weak self, weak item] in
                guard let self, let item else { return }
                self.stopForSystem(item, token: token)
            }
            try Task.checkCancellation()
            item.backgroundNotice = notice
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            item.job.state = .resolving
            item.preparationLabel = "Finding media"
            save()
            let ticker = startProgressTicker(for: item, background: background)
            defer { ticker.cancel() }
            let plan = try await MediaEngine.shared.download(
                job: item.job, cache: support.appendingPathComponent("ExtractorCache"), directory: directory,
                token: token
            ) { [weak self, weak item] event in
                guard let self, let item, item.job.state.isActive, !token.isCancelled else { return }
                self.apply(event, to: item)
            }
            try Task.checkCancellation()
            if item.job.kind == .images {
                try await saveGallery(plan, for: item, from: directory)
            } else {
                try await saveMedia(plan, for: item, in: directory, token: token)
            }
            item.job.progress = 1
            item.job.completed = Date()
            item.job.state = .completed
            Haptics.success()
        } catch {
            recordFailure(error, for: item)
        }
        await finishRun(item, directory: directory, background: background)
    }

    /// iOS expired the background task, or the user stopped it from the system progress UI.
    private func stopForSystem(_ item: JobItem, token: OperationToken) {
        guard item.job.state.isActive else { return }
        token.cancel()
        runner?.cancel()
        item.job.state = .failed
        item.job.error =
            "Background download stopped by iOS or cancelled from system progress. Add the link again to retry."
        message = item.job.error
        save()
    }

    private func startProgressTicker(for item: JobItem, background: DownloadBackgroundSession) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                guard let self else { break }
                activeTransfer?.refresh()
                let snapshot = progressSnapshot(item)
                background.update(snapshot)
                if !background.showsSystemProgress { liveActivity.update(snapshot) }
            }
        }
    }

    private func progressSnapshot(_ item: JobItem) -> BackgroundDownloadProgress {
        BackgroundDownloadProgress(
            title: item.job.title, state: item.job.state, fraction: item.progress,
            known: item.progressKnown, phase: item.phase, paused: item.isPaused,
            receivedBytes: item.receivedBytes, speed: item.speed, eta: item.eta,
            hideDetails: AppLockServices.controller.isEnabled)
    }

    private func apply(_ event: DownloadEvent, to item: JobItem) {
        switch event.type {
        case "resolved":
            guard let plan = event.plan else { return }
            item.job.title = plan.title
            item.job.author = plan.author
            item.job.thumbnail = plan.thumbnail
            item.job.state = .downloading
            item.isStreaming = false
            if item.job.kind != .images { activeTransfer = JobTransferProgress(item: item, tracks: plan.tracks) }
        case "galleryProgress":
            item.receivedBytes = event.bytes ?? item.receivedBytes
            item.progress = min(1, max(0, event.fraction ?? 0))
            item.progressKnown = true
            item.speed = event.speed ?? 0
            item.preparationLabel = "Image \(event.imageIndex ?? 1) of \(event.imageCount ?? 1)"
        case "progress":
            guard let index = event.index else { return }
            activeTransfer?.update(
                index: index, bytes: event.bytes ?? 0, total: event.total ?? 0, speed: event.speed, eta: event.eta)
        default:
            break
        }
    }

    /// Names that completed records still own, even if the file was moved in Files.
    private var reservedNames: Set<String> { Set(items.compactMap(\.job.filename)) }

    private func saveGallery(_ plan: MediaPlan, for item: JobItem, from directory: URL) async throws {
        guard let galleryFiles = plan.galleryFiles else {
            throw EngineFailure(message: "The gallery returned no files.")
        }
        try await pauseControl.wait()
        item.job.state = .processing
        item.phase = .saving
        item.progressKnown = false
        item.job.warning = plan.warnings?.joined(separator: " · ")
        let name = try LibraryFiles.publishGallery(
            directory.appendingPathComponent("gallery"), files: galleryFiles, to: documents,
            title: plan.title, reservedNames: reservedNames)
        item.job.filename = name
        item.job.galleryFiles = galleryFiles
        item.job.bytes = galleryFiles.reduce(0) { $0 + $1.bytes }
    }

    private func saveMedia(_ plan: MediaPlan, for item: JobItem, in directory: URL, token: OperationToken)
        async throws
    {
        item.job.sponsorSegmentsFound = plan.sponsorSegments?.count ?? 0
        item.job.warning = plan.subtitleWarning
        for warning in plan.warnings ?? [] { addWarning(warning, to: item) }
        try await pauseControl.wait()
        item.job.state = .processing
        item.progress = 0
        item.progressKnown = false
        item.phase = .preparing
        item.speed = 0
        item.eta = nil
        save()
        let cover = try await prepareCover(for: plan, item: item, in: directory)
        let staged = try await process(plan, for: item, cover: cover, in: directory, token: token)
        try await pauseControl.wait()
        item.phase = .saving
        item.progressKnown = false
        item.job.savedMediaInfo = await MediaEngine.shared.probe(staged, token: token)
        try Task.checkCancellation()
        let size = try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw EngineFailure(message: "The processed file is empty.") }
        item.job.filename = try LibraryFiles.publish(
            staged, to: documents, title: plan.title, reservedNames: reservedNames)
        item.job.bytes = Int64(size)
    }

    /// Downloads the thumbnail to embed. A failed download only adds a warning; cancellation propagates.
    private func prepareCover(for plan: MediaPlan, item: JobItem, in directory: URL) async throws -> URL? {
        guard item.job.effectiveOptions.embedThumbnail else { return nil }
        item.preparationLabel = "Preparing thumbnail"
        do {
            return try await EmbeddedArtwork.prepare(
                url: plan.thumbnail, destination: directory.appendingPathComponent("cover.jpg"))
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            addWarning(ArtworkRecovery.warning, to: item)
            return nil
        }
    }

    /// Remuxes the downloaded tracks, retrying without artwork or subtitles if either one fails.
    private func process(
        _ plan: MediaPlan, for item: JobItem, cover: URL?, in directory: URL, token: OperationToken
    ) async throws -> URL {
        let options = item.job.effectiveOptions
        // Media bytes are already local; FFmpeg only processes local inputs.
        let inputs = plan.tracks.map(\.url)
        let processed = try await ArtworkRecovery.finish(cover: cover) { artwork in
            let captions = try await SubtitleRecovery.finish(subtitle: plan.subtitle) { subtitle in
                let attempt = UUID()
                item.processingAttempt = attempt
                defer { if item.processingAttempt == attempt { item.processingAttempt = nil } }
                return try await MediaEngine.shared.remux(
                    inputs: inputs, output: directory.appendingPathComponent("finished"),
                    audioOnly: item.job.kind == .audio, token: token,
                    cover: artwork, segments: plan.sponsorSegments ?? [], sponsorMode: options.sponsorMode,
                    subtitle: subtitle
                ) { [weak item] phase, progress in
                    Task { @MainActor in
                        guard let item, item.job.state == .processing, !item.isPaused,
                            item.processingAttempt == attempt
                        else { return }
                        let samePhase = item.phase == phase
                        item.phase = phase
                        item.progressKnown = progress != nil
                        item.progress = progress.map { samePhase ? max(item.progress, $0) : $0 } ?? 0
                    }
                }
            }
            if let warning = captions.warning { addWarning(warning, to: item) }
            return captions.url
        }
        if let warning = processed.warning { addWarning(warning, to: item) }
        return processed.url
    }

    private func addWarning(_ warning: String, to item: JobItem) {
        item.job.warning = DownloadWarnings.appending(warning, to: item.job.warning)
    }

    private func recordFailure(_ error: Error, for item: JobItem) {
        guard item.job.state.isActive else { return }
        let cancelled = Task.isCancelled
        item.job.state = cancelled ? .cancelled : .failed
        item.job.error = cancelled ? nil : error.localizedDescription
        item.speed = 0
        guard !cancelled else { return }
        Haptics.failure()
        failedSocialLink = nil
        let reason = error.localizedDescription
        message = reason
        if SocialPlatform.forURL(item.job.sourceURL)?.supportsCookies == true
            && (reason.localizedCaseInsensitiveContains("may require an authenticated session")
                || reason.localizedCaseInsensitiveContains("denied access"))
        {
            failedSocialLink = item.job.sourceURL
        }
    }

    private func finishRun(_ item: JobItem, directory: URL, background: DownloadBackgroundSession) async {
        item.isPaused = false
        activeTransfer = nil
        liveActivity.end(
            progressSnapshot(item), cancelled: item.job.state == .cancelled,
            inForeground: UIApplication.shared.applicationState == .active)
        DownloadNotifier.post(for: item.job, hideDetails: AppLockServices.controller.isEnabled)
        try? FileManager.default.removeItem(at: directory)
        if item.job.state != .completed { items.removeAll { $0.id == item.id } }
        save()
        // Finishing the system task may suspend the app immediately. Wait for
        // the history write so a background completion survives the next launch.
        await withCheckedContinuation { continuation in
            persistence.async { continuation.resume() }
        }
        self.token = nil
        runner = nil
        isDownloadOccupied = false
        backgroundSession = nil
        background.finish(success: item.job.state == .completed)
    }
}
