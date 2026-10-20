import Foundation
import Observation
import WrathCore

@Observable @MainActor final class SocialAccessStore {
    static let shared = SocialAccessStore()
    private(set) var revision = UUID()
    private(set) var cookieCounts: [SocialPlatform: Int] = [:]
    private(set) var errors: [SocialPlatform: String] = [:]
    private var browserUserAgents: [SocialPlatform: String] = [:]

    init() {
        for site in SocialPlatform.cookiePlatforms {
            // Discard the removed manual override; only browser-captured identities remain.
            UserDefaults.standard.removeObject(forKey: "socialUserAgent.\(site.rawValue)")
            browserUserAgents[site] = try? HTTPUserAgent.validated(
                UserDefaults.standard.string(forKey: "socialBrowserUserAgent.\(site.rawValue)") ?? "")
            do {
                if let data = try storage(for: site).read() {
                    cookieCounts[site] = try JSONDecoder().decode(SocialCookies.self, from: data).count
                }
            } catch {
                errors[site] = "Saved cookies could not be read. Disconnect and sign in again."
            }
        }
    }
    private func storage(for site: SocialPlatform) -> KeychainCookieStore {
        KeychainCookieStore(service: "app.wrath.downloader.social.\(site.rawValue)")
    }
    /// Import directly from a user-initiated first-party WebKit login.
    /// Unrelated identity-provider cookies are filtered before Keychain storage.
    func saveBrowserCookies(_ cookies: [HTTPCookie], for site: SocialPlatform, userAgent: String?) throws {
        let snapshot = cookies.map {
            SocialBrowserCookie(
                domain: $0.domain, path: $0.path, name: $0.name,
                value: $0.value, expires: $0.expiresDate, secure: $0.isSecure,
                httpOnly: $0.isHTTPOnly)
        }
        let parsed = try SocialCookies(browserCookies: snapshot, platform: site)
        try storage(for: site).write(JSONEncoder().encode(parsed))
        cookieCounts[site] = parsed.count
        errors[site] = nil
        // Match the User-Agent that was actually used to sign in. Unsupported
        // or empty browser values do not overwrite the saved browser identity.
        if let userAgent, let validated = try? HTTPUserAgent.validated(userAgent) {
            UserDefaults.standard.set(validated, forKey: "socialBrowserUserAgent.\(site.rawValue)")
            browserUserAgents[site] = validated
        }
        revision = UUID()
    }
    func removeCookies(for site: SocialPlatform) throws {
        try storage(for: site).remove()
        clearBrowserIdentity(for: site)
        cookieCounts[site] = 0
        errors[site] = nil
        revision = UUID()
    }
    private func clearBrowserIdentity(for site: SocialPlatform) {
        UserDefaults.standard.removeObject(forKey: "socialBrowserUserAgent.\(site.rawValue)")
        browserUserAgents[site] = nil
    }
    func snapshot(for url: URL) throws -> [String: String] {
        guard let site = SocialPlatform.forURL(url), site.supportsCookies else { return [:] }
        var result: [String: String] = ["platform": site.rawValue]
        if let data = try storage(for: site).read() {
            result["cookies"] = try JSONDecoder().decode(SocialCookies.self, from: data).contents
        }
        if let agent = browserUserAgents[site] { result["userAgent"] = agent }
        return result
    }
}
