import Foundation

#if canImport(Darwin)
    import Darwin
#endif

public enum LibraryFileError: LocalizedError {
    case invalidName, collision, invalidFile
    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a file name."
        case .collision: "A file with this name already exists. Choose another name."
        case .invalidFile: "This saved file is unavailable."
        }
    }
}

public struct FileDeletionReport: Sendable {
    public let deleted: Set<String>
    public let failures: [String: String]
}

public struct StorageSnapshot: Sendable {
    public let savedBytes: Int64
    public let temporaryBytes: Int64
    public let cacheBytes: Int64
    public let availableBytes: Int64?
}

public enum CacheMaintenance {
    public static func clearExtractor(in support: URL) throws {
        let cache = support.appendingPathComponent("ExtractorCache", isDirectory: true)
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
    }
}

/// Library scans and maintenance run on this actor's executor.
public actor LibraryFiles {
    private let documents: URL
    private let support: URL
    public init(documents: URL, support: URL) {
        self.documents = documents
        self.support = support
    }

    /// Publish without copying media bytes or overwriting an existing file.
    /// Runs synchronously at the download's commit point, so cancellation cannot
    /// interleave between publication and updating the completed queue record.
    public static func publish(
        _ staged: URL, to documents: URL, title: String, reservedNames: Set<String> = []
    ) throws -> String {
        let manager = FileManager.default
        let values = try staged.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
            throw LibraryFileError.invalidFile
        }
        let base = LinkInput.filename(title: title, extension: staged.pathExtension)
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        // Retained records still own their names when a file is moved in Files.
        // Match case and canonical Unicode variants conservatively for iOS volumes.
        let reserved = Set(reservedNames.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        var number = 1
        while true {
            let name = number == 1 ? base : "\(stem) (\(number)).\(ext)"
            if reserved.contains(name.precomposedStringWithCanonicalMapping.lowercased()) {
                number += 1
                continue
            }
            do {
                // App Support and Documents are on the same container volume.
                // Creating a link refuses existing files, directories, and links,
                // including names that appear after we select the candidate.
                try manager.linkItem(at: staged, to: documents.appendingPathComponent(name))
                // The download's working-directory cleanup also removes this alias
                // if removing the staged name fails after publication succeeds.
                try? manager.removeItem(at: staged)
                return name
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                number += 1
            }
        }
    }

    public static func publishGallery(
        _ staged: URL, files: [GalleryFile], to documents: URL, title: String, reservedNames: Set<String> = []
    ) throws -> String {
        let manager = FileManager.default
        let values = try staged.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
            !files.isEmpty, files.count <= 200, files.allSatisfy(\.isValid),
            Set(files.map(\.filename)).count == files.count,
            Set(try manager.contentsOfDirectory(atPath: staged.path)) == Set(files.map(\.filename))
        else { throw LibraryFileError.invalidFile }
        for file in files {
            let info = try staged.appendingPathComponent(file.filename).resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                Int64(info.fileSize ?? 0) == file.bytes
            else { throw LibraryFileError.invalidFile }
        }
        let base = (LinkInput.filename(title: title, extension: "mp4") as NSString).deletingPathExtension
        let reserved = Set(reservedNames.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        var number = 1
        while true {
            let name = number == 1 ? base : "\(base) (\(number))"
            if reserved.contains(name.precomposedStringWithCanonicalMapping.lowercased()) {
                number += 1
                continue
            }
            do {
                #if canImport(Darwin)
                    // Unlike ordinary rename(), this cannot replace even an empty
                    // directory created by Files between choosing and publishing.
                    if renamex_np(staged.path, documents.appendingPathComponent(name).path, UInt32(RENAME_EXCL)) != 0 {
                        if errno == EEXIST || errno == ENOTEMPTY {
                            number += 1
                            continue
                        }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                #else
                    try manager.moveItem(at: staged, to: documents.appendingPathComponent(name))
                #endif
                return name
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                number += 1
            }
        }
    }

    public static func renamedFilename(stem: String, original: String, isGallery: Bool = false) throws -> String {
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
        let cleaned = stem.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        guard !cleaned.isEmpty else { throw LibraryFileError.invalidName }
        var limited = ""
        for character in cleaned {
            guard limited.utf8.count + String(character).utf8.count <= 200 else { break }
            limited.append(character)
        }
        let ext = isGallery ? "" : (original as NSString).pathExtension
        return limited + (ext.isEmpty ? "" : "." + ext)
    }
    private func file(_ name: String, isGallery: Bool = false) throws -> URL {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent, name != ".", name != ".." else {
            throw LibraryFileError.invalidFile
        }
        let url = documents.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
        guard isGallery ? values.isDirectory == true : values.isRegularFile == true, values.isSymbolicLink != true
        else { throw LibraryFileError.invalidFile }
        return url
    }
    public func rename(_ original: String, stem: String, isGallery: Bool = false) throws -> String {
        let source = try file(original, isGallery: isGallery)
        let name = try Self.renamedFilename(stem: stem, original: original, isGallery: isGallery)
        if name == original { return original }
        let destination = documents.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw LibraryFileError.collision }
        do { try FileManager.default.moveItem(at: source, to: destination) } catch let error as CocoaError
            where error.code == .fileWriteFileExists
        { throw LibraryFileError.collision }
        return name
    }
    public func delete(_ names: [String], galleries: Set<String> = []) -> FileDeletionReport {
        var deleted = Set<String>()
        var failures: [String: String] = [:]
        for name in Set(names) {
            do {
                try FileManager.default.removeItem(at: file(name, isGallery: galleries.contains(name)))
                deleted.insert(name)
            } catch { failures[name] = error.localizedDescription }
        }
        return FileDeletionReport(deleted: deleted, failures: failures)
    }
    private func bytes(in directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard
            let files = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants])
        else { return 0 }
        var size: Int64 = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true, values.isSymbolicLink != true
            else { continue }
            size += Int64(values.fileSize ?? 0)
        }
        return size
    }
    public func storage(thumbnailBytes: Int64) -> StorageSnapshot {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: documents.path)
        return StorageSnapshot(
            savedBytes: bytes(in: documents), temporaryBytes: bytes(in: support.appendingPathComponent("Working")),
            cacheBytes: bytes(in: support.appendingPathComponent("ExtractorCache")) + thumbnailBytes,
            availableBytes: (attributes?[.systemFreeSize] as? NSNumber)?.int64Value)
    }
}
