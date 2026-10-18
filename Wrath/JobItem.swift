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
    @ObservationIgnored var processingAttempt: UUID?
    nonisolated let id: UUID
    init(_ job: DownloadJob) {
        self.job = job
        id = job.id
    }
}
