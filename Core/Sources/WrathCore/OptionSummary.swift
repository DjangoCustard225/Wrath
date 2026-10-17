import Foundation

public enum OptionSummary {
    public static func text(availability: CodecAvailability, kind: MediaKind, options: DownloadOptions, isYouTube: Bool)
        -> String
    {
        var parts: [String] = []
        if kind == .video { parts.append(options.videoCodec == .automatic ? "Auto video" : options.videoCodec.label) }
        if availability.mediaKinds.contains(.audio) {
            parts.append(options.audioCodec == .automatic ? "Auto audio" : options.audioCodec.label)
        }
        if availability.thumbnailAvailable && options.embedThumbnail { parts.append("Thumbnail") }
        if kind == .video && options.embedSubtitles && !availability.subtitles.isEmpty {
            parts.append(
                availability.subtitles.first { $0.id == options.subtitleTrack }.map { "Subtitles: \($0.label)" }
                    ?? "Subtitles: Auto")
        }
        if isYouTube && options.sponsorMode != .off { parts.append("SponsorBlock: \(options.sponsorMode.label)") }
        return parts.joined(separator: " · ")
    }
}
