import Foundation
import Observation
import WrathCore

@Observable @MainActor final class SocialAccessStore {
    static let shared = SocialAccessStore()
    private(set) var revision = UUID()
    private(set) var cookieCounts: [SocialPlatform: Int] = [:]
    private(set) var errors: [SocialPlatform: String] = [:]
    private(set) var userAgents: [SocialPlatform: String] = [:]

    init() {
        for site in SocialPlatform.cookiePlatforms {
            userAgents[site] = try? HTTPUserAgent.validated(
                UserDefaults.standard.string(forKey: "socialUserAgent.\(site.rawValue)") ?? "")
            do {
                if let data = try storage(for: site).read() {
                    cookieCounts[site] = try JSONDecoder().decode(SocialCookies.self, from: data).count
                }
            } catch {
                errors[site] = "Saved cookies could not be read. Remove them and import a fresh export."
            }
        }
    }
    private func storage(for site: SocialPlatform) -> KeychainCookieStore {
        KeychainCookieStore(service: "app.wrath.downloader.social.\(site.rawValue)")
    }
    func importCookies(_ data: Data, for site: SocialPlatform) throws {
        let cookies = try SocialCookies(data: data, platform: site)
        try storage(for: site).write(JSONEncoder().encode(cookies))
        cookieCounts[site] = cookies.count
        errors[site] = nil
        revision = UUID()
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
        // or empty browser values do not overwrite the existing preference.
        if let userAgent, let validated = try? HTTPUserAgent.validated(userAgent) {
            UserDefaults.standard.set(validated, forKey: "socialUserAgent.\(site.rawValue)")
            userAgents[site] = validated
        }
        revision = UUID()
    }
    func removeCookies(for site: SocialPlatform) throws {
        try storage(for: site).remove()
        cookieCounts[site] = 0
        errors[site] = nil
        revision = UUID()
    }
    func saveUserAgent(_ value: String, for site: SocialPlatform) throws {
        let agent = try HTTPUserAgent.validated(value)
        UserDefaults.standard.set(agent, forKey: "socialUserAgent.\(site.rawValue)")
        userAgents[site] = agent
        revision = UUID()
    }
    func snapshot(for url: URL) throws -> [String: String] {
        guard let site = SocialPlatform.forURL(url), site.supportsCookies else { return [:] }
        var result: [String: String] = ["platform": site.rawValue]
        if let data = try storage(for: site).read() {
            result["cookies"] = try JSONDecoder().decode(SocialCookies.self, from: data).contents
        }
        if let agent = userAgents[site] { result["userAgent"] = agent }
        return result
    }
}
