import Foundation

/// Which saved files the Photos library accepts. Audio, Matroska and WebM files stay in Files.
public enum PhotoLibraryCompatibility {
    public enum Resource: Equatable, Sendable { case photo, video }

    private static let photos: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "avif"]
    private static let videos: Set<String> = ["mp4", "m4v", "mov"]

    public static func resource(forFilename name: String) -> Resource? {
        let ext = (name as NSString).pathExtension.lowercased()
        if photos.contains(ext) { return .photo }
        if videos.contains(ext) { return .video }
        return nil
    }

    /// Whether a completed download, or at least one photo in its gallery, can be saved to Photos.
    public static func canSave(_ job: DownloadJob) -> Bool {
        guard job.state == .completed else { return false }
        if job.kind == .images {
            return job.galleryFiles?.contains { resource(forFilename: $0.filename) != nil } ?? false
        }
        return job.kind == .video && job.filename.flatMap(resource(forFilename:)) == .video
    }
}
