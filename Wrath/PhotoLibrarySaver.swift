@preconcurrency import Photos
import WrathCore

/// Adds saved videos and photos to the Photos library with add-only access.
enum PhotoLibrarySaver {
    enum Failure: LocalizedError {
        case denied, nothingToSave
        var errorDescription: String? {
            switch self {
            case .denied: "Wrath can’t add to Photos. Allow it in Settings › Privacy & Security › Photos."
            case .nothingToSave: "Photos can’t import this file type. Use Share › Save to Files instead."
            }
        }
    }

    /// Saves every file Photos accepts, skipping the rest, and returns how many were saved.
    static func save(_ urls: [URL]) async throws -> Int {
        let files = urls.compactMap { url in
            PhotoLibraryCompatibility.resource(forFilename: url.lastPathComponent).map { (url, $0) }
        }
        guard !files.isEmpty else { throw Failure.nothingToSave }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.denied }
        try await PHPhotoLibrary.shared().performChanges {
            for (url, resource) in files {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                PHAssetCreationRequest.forAsset().addResource(
                    with: resource == .video ? .video : .photo, fileURL: url, options: options)
            }
        }
        return files.count
    }
}
