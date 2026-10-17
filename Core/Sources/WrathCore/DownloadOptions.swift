import Foundation

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case automatic, h264, hevc, av1, vp9
    public var label: String {
        switch self {
        case .automatic: "Automatic"
        case .h264: "H.264"
        case .hevc: "HEVC (H.265)"
        case .av1: "AV1"
        case .vp9: "VP9"
        }
    }
}
public enum AudioCodec: String, Codable, CaseIterable, Sendable {
    case automatic, aac, opus
    public var label: String { self == .automatic ? "Automatic" : rawValue.uppercased() }
}
public enum SponsorMode: String, Codable, CaseIterable, Sendable {
    case off, chapters, remove
    public var label: String {
        switch self {
        case .off: "Off"
        case .chapters: "Mark chapters"
        case .remove: "Remove segments"
        }
    }
}
public enum SponsorCategory: String, Codable, CaseIterable, Sendable {
    case sponsor, selfpromo, interaction, intro, outro, preview
    case musicOfftopic = "music_offtopic"
    case filler
    public var label: String {
        switch self {
        case .sponsor: "Sponsors"
        case .selfpromo: "Self-promotion"
        case .interaction: "Subscribe & like reminders"
        case .intro: "Intros"
        case .outro: "Outros"
        case .preview: "Previews"
        case .musicOfftopic: "Non-music sections"
        case .filler: "Filler"
        }
    }
    public var index: Int { Self.allCases.firstIndex(of: self)! }
}
public struct SponsorSegment: Codable, Sendable {
    public let start: Double
    public let end: Double
    public let category: SponsorCategory
}
public struct DownloadOptions: Codable, Equatable, Sendable {
    public var videoCodec: VideoCodec = .automatic
    public var audioCodec: AudioCodec = .automatic
    public var embedThumbnail = false
    public var embedSubtitles = false
    public var subtitleTrack = "automatic"
    public var sponsorMode: SponsorMode = .off
    public var sponsorCategories: Set<SponsorCategory> = [.sponsor]
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case videoCodec, audioCodec, embedThumbnail, embedSubtitles, subtitleTrack, sponsorMode, sponsorCategories
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        videoCodec = try values.decodeIfPresent(VideoCodec.self, forKey: .videoCodec) ?? .automatic
        audioCodec = try values.decodeIfPresent(AudioCodec.self, forKey: .audioCodec) ?? .automatic
        embedThumbnail = try values.decodeIfPresent(Bool.self, forKey: .embedThumbnail) ?? false
        embedSubtitles = try values.decodeIfPresent(Bool.self, forKey: .embedSubtitles) ?? false
        subtitleTrack = try values.decodeIfPresent(String.self, forKey: .subtitleTrack) ?? "automatic"
        sponsorMode = try values.decodeIfPresent(SponsorMode.self, forKey: .sponsorMode) ?? .off
        sponsorCategories =
            try values.decodeIfPresent(Set<SponsorCategory>.self, forKey: .sponsorCategories) ?? [.sponsor]
    }
    public func forSource(_ url: URL) -> DownloadOptions {
        var result = self
        if YouTubeLink.videoID(url) == nil { result.sponsorMode = .off }
        return result
    }
}
public enum YouTubeLink {
    public static func videoID(_ url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let parts = url.pathComponents.filter { $0 != "/" }
        let candidate: String?
        if host == "youtu.be" || host == "www.youtu.be" {
            candidate = parts.first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com"
            || host == "www.youtube-nocookie.com"
        {
            if ["shorts", "embed", "live"].contains(parts.first ?? ""), parts.count > 1 {
                candidate = parts[1]
            } else if parts == ["watch"] {
                candidate =
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" }
                    )?.value
            } else {
                return nil
            }
        } else {
            return nil
        }
        guard let candidate, candidate.utf8.count == 11,
            candidate.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
            })
        else { return nil }
        return candidate
    }
}
