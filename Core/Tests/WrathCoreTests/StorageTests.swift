import Foundation
import Testing

@testable import WrathCore

@Suite struct SocialCookiesTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func cookie(
        domain: String = ".reddit.com", name: String = "session", value: String = "abc", expires: Date? = nil,
        httpOnly: Bool = false
    ) -> SocialBrowserCookie {
        SocialBrowserCookie(
            domain: domain, path: "/", name: name, value: value, expires: expires, secure: true, httpOnly: httpOnly)
    }

    @Test func exportsOnlyFirstPartyCookies() throws {
        let cookies = try SocialCookies(
            browserCookies: [
                cookie(httpOnly: true),
                cookie(domain: ".google.com", name: "SID"),
                cookie(name: "old", expires: Date(timeIntervalSince1970: 10)),
            ], platform: .reddit, now: now)
        #expect(cookies.count == 1)
        #expect(
            cookies.contents == "# Netscape HTTP Cookie File\n#HttpOnly_.reddit.com\tTRUE\t/\tTRUE\t0\tsession\tabc\n")
    }

    @Test func skipsValuesThatCannotBeExportedSafely() throws {
        let cookies = try SocialCookies(
            browserCookies: [cookie(), cookie(name: "bad", value: "a;b")], platform: .reddit, now: now)
        #expect(cookies.count == 1)
    }

    @Test func requiresAtLeastOneCookie() {
        #expect(throws: SocialCookiesError.noCookies) {
            try SocialCookies(browserCookies: [cookie(domain: ".google.com")], platform: .reddit, now: now)
        }
    }

    @Test func roundTripsItsOwnExport() throws {
        let exported = try SocialCookies(browserCookies: [cookie()], platform: .reddit, now: now)
        let decoded = try SocialCookies(data: Data(exported.contents.utf8), platform: .reddit, now: now)
        #expect(decoded.contents == exported.contents)
    }
}

@Suite struct HTTPUserAgentTests {
    @Test func validatesUserAgents() throws {
        #expect(try HTTPUserAgent.validated("  Mozilla/5.0  ") == "Mozilla/5.0")
        #expect(try HTTPUserAgent.validated("") == nil)
        #expect(throws: HTTPUserAgentError.self) { try HTTPUserAgent.validated("a\nb") }
    }
}

@Suite struct LibraryFilesTests {
    private let root: URL
    private let documents: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        documents = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    }

    private func staged(_ name: String, contents: String = "media") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func publishesWithoutOverwriting() throws {
        let first = try LibraryFiles.publish(try staged("a.mp4"), to: documents, title: "Clip")
        let second = try LibraryFiles.publish(try staged("b.mp4"), to: documents, title: "Clip")
        let reserved = try LibraryFiles.publish(
            try staged("c.mp4"), to: documents, title: "Clip", reservedNames: ["CLIP (3).mp4"])
        #expect([first, second, reserved] == ["Clip.mp4", "Clip (2).mp4", "Clip (4).mp4"])
    }

    @Test func refusesEmptyFiles() throws {
        let empty = try staged("empty.mp4", contents: "")
        #expect(throws: LibraryFileError.invalidFile) { try LibraryFiles.publish(empty, to: documents, title: "x") }
    }

    @Test func renamesKeepingTheExtension() async throws {
        let files = LibraryFiles(documents: documents, support: root)
        let name = try LibraryFiles.publish(try staged("a.mp4"), to: documents, title: "Clip")
        #expect(try await files.rename(name, stem: " New: name ") == "New_ name.mp4")
        await #expect(throws: LibraryFileError.invalidName) { try await files.rename("New_ name.mp4", stem: " .. ") }
    }

    @Test func deletesOnlyPlainNames() async throws {
        let files = LibraryFiles(documents: documents, support: root)
        let name = try LibraryFiles.publish(try staged("a.mp4"), to: documents, title: "Clip")
        let report = await files.delete([name, "../escape"])
        #expect(report.deleted == [name])
        #expect(report.failures.keys.contains("../escape"))
    }
}

@Suite struct DownloadPauseControlTests {
    @Test func waitsWhilePausedAndResumes() async throws {
        let control = DownloadPauseControl()
        control.setPaused(true)
        let waiter = Task { try await control.wait() }
        try await Task.sleep(for: .milliseconds(20))
        control.setPaused(false)
        try await waiter.value
    }

    @Test func cancellationReleasesAWaiter() async throws {
        let control = DownloadPauseControl()
        control.setPaused(true)
        let waiter = Task { try await control.wait() }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
    }
}

@MainActor @Suite struct LinkInspectorTests {
    private let url = URL(string: "https://example.com/video")!

    @Test func keepsTheResultForTheSameRequest() async {
        let calls = Counter()
        let inspector = LinkInspector(debounce: .zero) { _ in
            await calls.increment()
            return CodecAvailability(choices: [])
        }
        await inspector.inspect(url)
        await inspector.inspect(url)
        #expect(await calls.value == 1)
        #expect(inspector.availability != nil)
        inspector.revision += 1
        await inspector.inspect(url)
        #expect(await calls.value == 2)
    }

    @Test func reportsErrors() async {
        let inspector = LinkInspector(debounce: .zero) { _ in throw CocoaError(.fileReadNoSuchFile) }
        await inspector.inspect(url)
        #expect(inspector.error != nil)
        #expect(!inspector.loading)
    }

    @Test func timesOutSlowInspections() async {
        let inspector = LinkInspector(debounce: .zero, timeout: .milliseconds(30)) { _ in
            try await Task.sleep(for: .seconds(5))
            return CodecAvailability(choices: [])
        }
        await inspector.inspect(url)
        #expect(inspector.error == "Checking this link took too long. Retry to read its available formats.")
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
