import Foundation
import Testing

@testable import WrathCore

@Suite struct LinkInputTests {
    @Test func acceptsPlainLinksAndAddsHTTPS() {
        #expect(LinkInput.parse("example.com/video")?.absoluteString == "https://example.com/video")
        #expect(LinkInput.parse("  https://youtu.be/abcdefghijk \n")?.host == "youtu.be")
    }

    @Test func rejectsUnsupportedSchemesAndCredentials() {
        #expect(LinkInput.parse("") == nil)
        #expect(LinkInput.parse("ftp://example.com/file") == nil)
        #expect(LinkInput.parse("https://user:secret@example.com/") == nil)
    }

    @Test func extractsASingleSocialLinkFromSharedText() {
        let shared = "Look at this https://www.instagram.com/p/abc123/."
        #expect(LinkInput.parse(shared)?.absoluteString == "https://www.instagram.com/p/abc123/")
    }

    @Test func ignoresUnrelatedOrAmbiguousLinksInText() {
        #expect(LinkInput.parse("see https://example.com/page please") == nil)
        #expect(LinkInput.parse("https://youtu.be/a and https://youtu.be/b") == nil)
    }

    @Test func buildsSafeFilenames() {
        #expect(LinkInput.filename(title: "a/b:c?", extension: "mp4") == "a_b_c_.mp4")
        #expect(LinkInput.filename(title: "  ...  ", extension: "mp4") == "Download.mp4")
        #expect(LinkInput.filename(title: "Clip", extension: "exe") == "Clip.mkv")
        let long = LinkInput.filename(title: String(repeating: "é", count: 300), extension: "m4a")
        #expect(long.utf8.count <= 180 + ".m4a".utf8.count)
    }
}

@Suite struct YouTubeLinkTests {
    @Test(arguments: [
        "https://youtu.be/dQw4w9WgXcQ",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://m.youtube.com/shorts/dQw4w9WgXcQ",
        "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ",
    ])
    func recognizesVideoLinks(_ link: String) throws {
        #expect(YouTubeLink.videoID(try #require(URL(string: link))) == "dQw4w9WgXcQ")
    }

    @Test(arguments: [
        "https://www.youtube.com/playlist?list=PL123",
        "https://youtube.com.evil.test/watch?v=dQw4w9WgXcQ",
        "https://youtu.be/short",
    ])
    func rejectsOtherLinks(_ link: String) throws {
        #expect(YouTubeLink.videoID(try #require(URL(string: link))) == nil)
    }
}

@Suite struct SocialPlatformTests {
    @Test func matchesFirstPartyHostsOnly() throws {
        #expect(SocialPlatform.forURL(try #require(URL(string: "https://old.reddit.com/r/a"))) == .reddit)
        #expect(SocialPlatform.forURL(try #require(URL(string: "https://instagram.com.evil.test/p/a"))) == nil)
        #expect(SocialPlatform.forURL(try #require(URL(string: "http://www.instagram.com/p/a"))) == nil)
    }

    @Test func cookieDomainsFollowThePlatform() {
        #expect(SocialPlatform.reddit.acceptsCookieDomain(".reddit.com"))
        #expect(!SocialPlatform.reddit.acceptsCookieDomain(".accounts.google.com"))
    }
}
