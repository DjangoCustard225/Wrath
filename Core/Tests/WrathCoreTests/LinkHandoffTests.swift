import Foundation
import Testing

@testable import WrathCore

@MainActor @Suite struct LinkHandoffTests {
    @Test func deliversAParsedLinkOnce() {
        let handoff = LinkHandoff()
        #expect(handoff.send("youtu.be/dQw4w9WgXcQ"))
        #expect(handoff.take()?.url == URL(string: "https://youtu.be/dQw4w9WgXcQ"))
        #expect(handoff.take() == nil)
    }

    @Test func rejectsTextWithoutALink() {
        let handoff = LinkHandoff()
        #expect(!handoff.send("not a link at all"))
        #expect(!handoff.send("ftp://example.com/file"))
        #expect(handoff.pending == nil)
    }

    @Test func keepsOnlyTheLatestLink() {
        let handoff = LinkHandoff()
        handoff.send("https://example.com/one")
        handoff.send("https://example.com/two")
        #expect(handoff.take()?.url == URL(string: "https://example.com/two"))
    }

    @Test func roundTripsSharedTextThroughTheAppLink() throws {
        let shared = "Look at this https://www.reddit.com/r/a/comments/b/c/?x=1&y=a+b#top"
        let url = try #require(LinkHandoff.appURL(for: shared))
        #expect(url.scheme == "wrath")
        let handoff = LinkHandoff()
        #expect(handoff.receive(url))
        #expect(handoff.take()?.url == URL(string: "https://www.reddit.com/r/a/comments/b/c/?x=1&y=a+b#top"))
    }

    @Test func ignoresOtherAppLinks() throws {
        let handoff = LinkHandoff()
        let encoded = "https%3A%2F%2Fyoutu.be%2Fabc"
        #expect(!handoff.receive(try #require(URL(string: "wrath://settings?link=\(encoded)"))))
        #expect(!handoff.receive(try #require(URL(string: "other://add?link=\(encoded)"))))
        #expect(!handoff.receive(try #require(URL(string: "wrath://add"))))
        #expect(handoff.receive(try #require(URL(string: "wrath://add?link=\(encoded)"))))
    }

    @Test func refusesEmptyOrOversizedText() {
        #expect(LinkHandoff.appURL(for: "  \n") == nil)
        let long = "https://example.com/" + String(repeating: "a", count: 5000)
        #expect(LinkHandoff.appURL(for: long)?.absoluteString.count ?? .max < 4096 * 3 + 30)
    }

    @Test func carriesShareSheetChoices() throws {
        let preset = SharePreset(kind: .audio, quality: .hd, startNow: true)
        let url = try #require(LinkHandoff.appURL(for: "https://youtu.be/abc", preset: preset))
        let handoff = LinkHandoff()
        #expect(handoff.receive(url))
        #expect(handoff.take() == SharedLink(url: try #require(URL(string: "https://youtu.be/abc")), preset: preset))
    }

    @Test func ignoresUnknownChoices() throws {
        let handoff = LinkHandoff()
        let url = try #require(
            URL(string: "wrath://add?link=https%3A%2F%2Fyoutu.be%2Fabc&kind=images&quality=-4&start=yes"))
        #expect(handoff.receive(url))
        #expect(handoff.take()?.preset == SharePreset.none)
    }
}
