import Foundation

public struct SubtitleChoice: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let language: String
    public let name: String
    public let automatic: Bool
    public init(id: String, language: String, name: String, automatic: Bool = false) {
        self.id = id
        self.language = language
        self.name = name
        self.automatic = automatic
    }
    public var label: String { automatic ? "\(name) · Auto-generated" : name }
}

public struct CodecChoice: Codable, Equatable, Sendable {
    public let kind: MediaKind
    public let quality: Quality
    public let videoCodec: VideoCodec
    public let audioCodec: AudioCodec
    public let estimatedBytes: Int64?
    public init(
        kind: MediaKind, quality: Quality, videoCodec: VideoCodec, audioCodec: AudioCodec, estimatedBytes: Int64? = nil
    ) {
        self.kind = kind
        self.quality = quality
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.estimatedBytes = estimatedBytes
    }
}

public struct CodecAvailability: Codable, Equatable, Sendable {
    public let choices: [CodecChoice]
    public let thumbnailAvailable: Bool
    public let thumbnail: URL?
    public let subtitles: [SubtitleChoice]
    public let exactQualities: Bool
    public let title: String?
    public let author: String?
    public let duration: Double?
    public let formatCount: Int?
    public let maxHeight: Int?
    public let estimatedBytes: Int64?
    public init(
        choices: [CodecChoice], thumbnailAvailable: Bool = false, title: String? = nil,
        author: String? = nil, duration: Double? = nil, formatCount: Int? = nil,
        maxHeight: Int? = nil, estimatedBytes: Int64? = nil, exactQualities: Bool = false,
        subtitles: [SubtitleChoice] = [], thumbnail: URL? = nil
    ) {
        self.choices = choices
        self.thumbnailAvailable = thumbnailAvailable
        self.title = title
        self.author = author
        self.duration = duration
        self.formatCount = formatCount
        self.maxHeight = maxHeight
        self.estimatedBytes = estimatedBytes
        self.exactQualities = exactQualities
        self.subtitles = subtitles
        self.thumbnail = thumbnail
    }
    private enum CodingKeys: String, CodingKey {
        case choices, thumbnailAvailable, thumbnail, subtitles, exactQualities, title, author, duration, formatCount,
            maxHeight, estimatedBytes
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        choices = try values.decode([CodecChoice].self, forKey: .choices)
        thumbnailAvailable = try values.decodeIfPresent(Bool.self, forKey: .thumbnailAvailable) ?? false
        thumbnail = try values.decodeIfPresent(URL.self, forKey: .thumbnail)
        subtitles = try values.decodeIfPresent([SubtitleChoice].self, forKey: .subtitles) ?? []
        exactQualities = try values.decodeIfPresent(Bool.self, forKey: .exactQualities) ?? false
        title = try values.decodeIfPresent(String.self, forKey: .title)
        author = try values.decodeIfPresent(String.self, forKey: .author)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration)
        formatCount = try values.decodeIfPresent(Int.self, forKey: .formatCount)
        maxHeight = try values.decodeIfPresent(Int.self, forKey: .maxHeight)
        estimatedBytes = try values.decodeIfPresent(Int64.self, forKey: .estimatedBytes)
    }
    private func matches(_ choice: CodecChoice, kind: MediaKind, quality: Quality) -> Bool {
        choice.kind == kind && (kind == .audio || choice.quality == quality)
    }
    public var mediaKinds: [MediaKind] {
        MediaKind.allCases.filter { kind in choices.contains { $0.kind == kind } }
    }
    public var qualities: [Quality] {
        let values = Set(choices.filter { $0.kind == .video }.map(\.quality))
        return values.sorted {
            if $0 == .best { return $1 != .best }
            if $1 == .best { return false }
            return $0.rawValue > $1.rawValue
        }
    }
    public func resolvingQuality(_ preferred: Quality) -> Quality {
        if qualities.contains(preferred) { return preferred }
        return qualities.first { $0 != .best && $0.rawValue <= preferred.rawValue } ?? .best
    }
    public func videoCodecs(quality: Quality) -> [VideoCodec] {
        VideoCodec.allCases.filter { codec in
            choices.contains {
                matches($0, kind: .video, quality: quality) && $0.videoCodec == codec && $0.audioCodec == .automatic
            }
        }
    }
    public func audioCodecs(kind: MediaKind, quality: Quality, videoCodec: VideoCodec) -> [AudioCodec] {
        AudioCodec.allCases.filter { codec in
            choices.contains {
                matches($0, kind: kind, quality: quality) && $0.audioCodec == codec
                    && (kind == .audio || $0.videoCodec == videoCodec)
            }
        }
    }
    public func supports(kind: MediaKind, quality: Quality, options: DownloadOptions) -> Bool {
        audioCodecs(kind: kind, quality: quality, videoCodec: options.videoCodec).contains(options.audioCodec)
    }
    public func estimatedSize(kind: MediaKind, quality: Quality, options: DownloadOptions) -> Int64? {
        choices.first {
            matches($0, kind: kind, quality: quality) && $0.audioCodec == options.audioCodec
                && (kind == .audio || $0.videoCodec == options.videoCodec)
        }?.estimatedBytes
    }
    public func resolving(_ options: DownloadOptions, kind: MediaKind, quality: Quality) -> DownloadOptions {
        var resolved = options
        if kind == .video && !videoCodecs(quality: quality).contains(resolved.videoCodec) {
            resolved.videoCodec = .automatic
        }
        if !audioCodecs(kind: kind, quality: quality, videoCodec: resolved.videoCodec).contains(resolved.audioCodec) {
            resolved.audioCodec = .automatic
        }
        if !subtitles.contains(where: { $0.id == resolved.subtitleTrack }) { resolved.subtitleTrack = "automatic" }
        return resolved
    }
    public func optionsForDownload(_ options: DownloadOptions, kind: MediaKind, quality: Quality) -> DownloadOptions {
        var resolved = resolving(options, kind: kind, quality: quality)
        resolved.embedThumbnail = options.embedThumbnail && thumbnailAvailable
        resolved.embedSubtitles = options.embedSubtitles && kind == .video && !subtitles.isEmpty
        return resolved
    }
}
