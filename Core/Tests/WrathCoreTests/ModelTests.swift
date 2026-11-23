import Foundation
import Testing

@testable import WrathCore

@Suite struct QualityTests {
    @Test func keepsIntegerEncoding() throws {
        let data = try JSONEncoder().encode(Quality.fullHD)
        #expect(String(decoding: data, as: UTF8.self) == "1080")
        #expect(try JSONDecoder().decode(Quality.self, from: Data("720".utf8)) == .hd)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Quality.self, from: Data("-1".utf8)) }
    }
}

@Suite struct DownloadOptionsTests {
    @Test func decodesMissingKeysAsDefaults() throws {
        let options = try JSONDecoder().decode(DownloadOptions.self, from: Data("{}".utf8))
        #expect(options == DownloadOptions())
    }

    @Test func disablesSponsorBlockOutsideYouTube() throws {
        var options = DownloadOptions()
        options.sponsorMode = .remove
        #expect(options.forSource(try #require(URL(string: "https://vimeo.com/1"))).sponsorMode == .off)
        let youtube = try #require(URL(string: "https://youtu.be/dQw4w9WgXcQ"))
        #expect(options.forSource(youtube).sponsorMode == .remove)
    }
}

@Suite struct CodecAvailabilityTests {
    private let availability = CodecAvailability(
        choices: [
            CodecChoice(kind: .video, quality: .fullHD, videoCodec: .automatic, audioCodec: .automatic),
            CodecChoice(kind: .video, quality: .fullHD, videoCodec: .h264, audioCodec: .automatic),
            CodecChoice(kind: .video, quality: .fullHD, videoCodec: .h264, audioCodec: .aac, estimatedBytes: 42),
            CodecChoice(kind: .video, quality: .hd, videoCodec: .automatic, audioCodec: .automatic),
            CodecChoice(kind: .audio, quality: .best, videoCodec: .automatic, audioCodec: .opus),
        ], thumbnailAvailable: true)

    @Test func ordersQualitiesFromHighest() {
        #expect(availability.qualities == [.fullHD, .hd])
        #expect(availability.mediaKinds == [.video, .audio])
    }

    @Test func resolvesToTheNearestLowerQuality() throws {
        #expect(availability.resolvingQuality(.fullHD) == .fullHD)
        #expect(availability.resolvingQuality(try #require(Quality(rawValue: 900))) == .hd)
        #expect(availability.resolvingQuality(.compact) == .best)
    }

    @Test func resetsUnavailableCodecs() {
        var options = DownloadOptions()
        options.videoCodec = .av1
        options.audioCodec = .opus
        options.subtitleTrack = "missing"
        let resolved = availability.resolving(options, kind: .video, quality: .hd)
        #expect(resolved.videoCodec == .automatic)
        #expect(resolved.audioCodec == .automatic)
        #expect(resolved.subtitleTrack == "automatic")
    }

    @Test func estimatesSizeForTheExactCombination() {
        var options = DownloadOptions()
        options.videoCodec = .h264
        options.audioCodec = .aac
        #expect(availability.estimatedSize(kind: .video, quality: .fullHD, options: options) == 42)
        #expect(availability.supports(kind: .video, quality: .fullHD, options: options))
        #expect(!availability.supports(kind: .video, quality: .hd, options: options))
    }

    @Test func dropsExtrasTheSourceCannotProvide() {
        var options = DownloadOptions()
        options.embedThumbnail = true
        options.embedSubtitles = true
        let resolved = availability.optionsForDownload(options, kind: .video, quality: .fullHD)
        #expect(resolved.embedThumbnail)
        #expect(!resolved.embedSubtitles)
    }

    @Test func galleriesOnlyOfferImages() {
        let gallery = CodecAvailability(choices: [], gallery: GalleryInfo(count: 3))
        #expect(gallery.mediaKinds == [.images])
        #expect(gallery.supports(kind: .images, quality: .best, options: DownloadOptions()))
    }
}

@Suite struct GalleryFileTests {
    @Test func acceptsOnlyPlainImageNames() {
        #expect(GalleryFile(filename: "001.jpg", bytes: 1).isValid)
        #expect(!GalleryFile(filename: "../001.jpg", bytes: 1).isValid)
        #expect(!GalleryFile(filename: ".hidden.jpg", bytes: 1).isValid)
        #expect(!GalleryFile(filename: "clip.mp4", bytes: 1).isValid)
        #expect(!GalleryFile(filename: "empty.png", bytes: 0).isValid)
    }
}

@Suite struct LibrarySortTests {
    @Test func breaksTiesStably() throws {
        let url = try #require(URL(string: "https://example.com"))
        var first = DownloadJob(url: url, kind: .video, quality: .best)
        var second = DownloadJob(url: url, kind: .video, quality: .best)
        let date = Date(timeIntervalSince1970: 1)
        first.created = date
        second.created = date
        first.bytes = 10
        second.bytes = 10
        let expected = first.id.uuidString < second.id.uuidString
        #expect(LibrarySort.largest.precedes(first, second) == expected)
        second.bytes = 20
        #expect(LibrarySort.largest.precedes(second, first))
        #expect(LibrarySort.smallest.precedes(first, second))
    }
}

@Suite struct DownloadWarningsTests {
    @Test func appendsWithoutDuplicates() {
        let once = DownloadWarnings.appending("Saved without thumbnail", to: nil)
        let twice = DownloadWarnings.appending("Saved without thumbnail", to: once)
        #expect(twice == "Saved without thumbnail")
        let both = DownloadWarnings.appending("Saved without subtitles", to: twice)
        #expect(DownloadWarnings.summary(both) == "Saved without thumbnail and subtitles")
    }

    @Test func hidesGenericGalleryWarnings() {
        #expect(DownloadWarnings.visible("Extractor noise", for: .images) == nil)
        #expect(DownloadWarnings.visible("Extractor noise", for: .video) == "Extractor noise")
    }
}
