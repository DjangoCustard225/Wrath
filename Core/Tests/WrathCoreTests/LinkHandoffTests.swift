import Foundation
import Testing

@testable import WrathCore

@MainActor @Suite struct LinkHandoffTests {
    @Test func deliversAParsedLinkOnce() {
        let handoff = LinkHandoff()
        #expect(handoff.send("youtu.be/dQw4w9WgXcQ"))
        #expect(handoff.take() == URL(string: "https://youtu.be/dQw4w9WgXcQ"))
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
        #expect(handoff.take() == URL(string: "https://example.com/two"))
    }
}
