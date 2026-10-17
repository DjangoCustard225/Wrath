import Foundation

public enum MediaKind: String, Codable, CaseIterable, Sendable { case video, audio }
public struct Quality: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init?(rawValue: Int) {
        guard (0...65536).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }
    public static let best = Quality(rawValue: 0)!
    public static let fullHD = Quality(rawValue: 1080)!
    public static let hd = Quality(rawValue: 720)!
    public static let compact = Quality(rawValue: 480)!
    public var label: String { self == .best ? "Best available" : "\(rawValue)p" }
    // Keep the integer encoding used by existing queue/preferences records.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Int.self)
        guard let quality = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid video resolution")
        }
        self = quality
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
public struct MediaTrack: Codable, Sendable {
    public let url: URL
    public let headers: [String: String]
    public let role: String
    public let streaming: Bool
    public let bytes: Int64?
    public let chunkSize: Int64?
    public init(
        url: URL, headers: [String: String] = [:], role: String = "video", streaming: Bool = false, bytes: Int64? = nil,
        chunkSize: Int64? = nil
    ) {
        self.url = url
        self.headers = headers
        self.role = role
        self.streaming = streaming
        self.bytes = bytes
        self.chunkSize = chunkSize
    }
}
public struct SubtitleCue: Codable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
}
public struct MediaSubtitle: Codable, Sendable {
    public let language: String
    public let name: String
    public let cues: [SubtitleCue]
}
public struct MediaPlan: Codable, Sendable {
    public let title: String
    public let author: String
    public let source: String
    public let duration: Double?
    public let thumbnail: URL?
    public let tracks: [MediaTrack]
    public let fileExtension: String
    public let quality: String
    public let sponsorSegments: [SponsorSegment]?
    public let subtitle: MediaSubtitle?
    public let subtitleWarning: String?
}
public enum JobState: String, Codable, Sendable {
    case queued, resolving, downloading, processing, completed, failed, cancelled
    public var isActive: Bool { [.resolving, .downloading, .processing].contains(self) }
    public var label: String { rawValue.capitalized }
}
public struct SavedSubtitleInfo: Codable, Sendable, Equatable {
    public let language: String?
    public let name: String?
}
public struct SavedMediaInfo: Codable, Sendable, Equatable {
    public let duration: Double?
    public let width: Int?
    public let height: Int?
    public let videoCodec: String?
    public let audioCodec: String?
    public let subtitles: [SavedSubtitleInfo]
}
public struct DownloadJob: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var sourceURL: URL
    public var kind: MediaKind
    public var quality: Quality
    public var title: String
    public var author = ""
    public var thumbnail: URL?
    public var state: JobState = .queued
    public var progress: Double = 0
    public var bytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var speed: Double = 0
    public var error: String?
    public var warning: String?
    public var filename: String?
    public var created = Date()
    public var completed: Date?
    public var options: DownloadOptions?
    public var sponsorSegmentsFound: Int?
    public var codecAvailability: CodecAvailability?
    public var savedMediaInfo: SavedMediaInfo?
    public var effectiveOptions: DownloadOptions { (options ?? DownloadOptions()).forSource(sourceURL) }
    public init(url: URL, kind: MediaKind, quality: Quality, options: DownloadOptions = DownloadOptions()) {
        sourceURL = url
        self.kind = kind
        self.quality = quality
        title = url.host ?? "New download"
        self.options = options
    }
}
public enum LinkInput {
    public static func parse(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else { return nil }
        let normalized = value.contains("://") ? value : "https://" + value
        guard let url = URL(string: normalized), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else { return nil }
        return url
    }
    public static func filename(title: String, extension ext: String) -> String {
        let cleaned = title.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || "/\\:*?\"<>|".unicodeScalars.contains($0) ? "_" : String($0)
        }.joined()
        var stem = ""
        for character in cleaned.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        {
            if stem.utf8.count + String(character).utf8.count > 180 { break }
            stem.append(character)
        }
        let safeExt = ["mp4", "mkv", "m4a", "opus", "ogg", "mp3", "webm", "flac", "wav"].contains(ext) ? ext : "mkv"
        return "\(stem.isEmpty ? "Download" : stem).\(safeExt)"
    }
}
