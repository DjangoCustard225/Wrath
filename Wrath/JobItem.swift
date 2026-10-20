import Foundation
import Observation
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
    var isPaused = false
    var preparationLabel = "Finding media"
    var backgroundNotice: String?
    @ObservationIgnored var processingAttempt: UUID?
    nonisolated let id: UUID
    init(_ job: DownloadJob) {
        self.job = job
        id = job.id
    }
    private var galleryDirectory: URL? {
        guard job.kind == .images, let name = job.filename, name == (name as NSString).lastPathComponent,
            !name.isEmpty, name != ".", name != "..",
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        return documents.appendingPathComponent(name, isDirectory: true)
    }
    var galleryURLs: [URL] {
        guard let directory = galleryDirectory else { return [] }
        return (job.galleryFiles ?? []).compactMap { file in
            file.isValid ? directory.appendingPathComponent(file.filename) : nil
        }
    }
    var libraryArtwork: URL? {
        guard job.kind == .images else { return job.thumbnail }
        guard let directory = galleryDirectory, let cover = job.galleryFiles?.first(where: \.isValid) else {
            return nil
        }
        return directory.appendingPathComponent(cover.filename)
    }
}
