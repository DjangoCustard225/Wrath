import Foundation

/// Explicit first-party domains only. A deceptive host such as instagram.com.evil.test
/// must never be allowed to access a saved login session.
public enum SocialPlatform: String, CaseIterable, Identifiable, Sendable {
    case instagram, tiktok, facebook, x, reddit, threads

    public static var cookiePlatforms: [Self] { allCases.filter(\.supportsCookies) }
    public var supportsCookies: Bool { self == .reddit }

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .instagram: "Instagram"
        case .tiktok: "TikTok"
        case .facebook: "Facebook"
        case .x: "X / Twitter"
        case .reddit: "Reddit"
        case .threads: "Threads"
        }
    }
    public var domains: [String] {
        switch self {
        case .instagram: ["instagram.com", "instagr.am"]
        case .tiktok: ["tiktok.com"]
        case .facebook: ["facebook.com", "fb.com", "fb.watch"]
        case .x: ["x.com", "twitter.com", "t.co"]
        case .reddit: ["reddit.com", "redd.it"]
        case .threads: ["threads.com", "threads.net"]
        }
    }
    public static func forURL(_ url: URL) -> SocialPlatform? {
        guard url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        else { return nil }
        return allCases.first { site in
            site.domains.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }
    public func acceptsCookieDomain(_ domain: String) -> Bool {
        let host = domain.lowercased().hasPrefix(".") ? String(domain.dropFirst()) : domain.lowercased()
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

public enum SocialCookiesError: LocalizedError {
    case invalidFile, tooLarge, noCookies
    public var errorDescription: String? {
        switch self {
        case .invalidFile: "Choose a valid Netscape-format cookies.txt export for this website."
        case .tooLarge: "Cookie export is too large. Export cookies for this website only."
        case .noCookies: "No unexpired cookies for this website were found. Export a fresh logged-in session."
        }
    }
}

/// Filter a browser export *before* saving it. Other websites' credentials are discarded.
public struct SocialCookies: Codable, Sendable {
    public static let maximumBytes = 512 * 1024
    public let contents: String
    public let count: Int

    public init(data: Data, platform: SocialPlatform, now: Date = Date()) throws {
        guard data.count <= Self.maximumBytes else { throw SocialCookiesError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw SocialCookiesError.invalidFile }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines =
            normalized.hasPrefix("\u{FEFF}")
            ? String(normalized.dropFirst()).components(separatedBy: "\n")
            : normalized.components(separatedBy: "\n")
        guard let header = lines.first,
            header == "# Netscape HTTP Cookie File" || header == "# HTTP Cookie File"
        else { throw SocialCookiesError.invalidFile }
        var kept: [String] = []
        for original in lines.dropFirst() {
            let httpOnly = original.hasPrefix("#HttpOnly_")
            let line = httpOnly ? String(original.dropFirst("#HttpOnly_".count)) : original
            if line.isEmpty || (!httpOnly && line.hasPrefix("#")) { continue }
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 7 else { throw SocialCookiesError.invalidFile }
            let domain = fields[0].lowercased()
            guard platform.acceptsCookieDomain(domain) else { continue }
            guard ["TRUE", "FALSE"].contains(fields[1]), ["TRUE", "FALSE"].contains(fields[3]),
                (fields[1] == "TRUE") == domain.hasPrefix("."),
                fields[2].hasPrefix("/"),
                !fields[5].isEmpty, fields[5].utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 59 && $0 != 61 }),
                fields[6].utf8.allSatisfy({ $0 >= 32 && $0 < 127 && $0 != 59 }),
                fields[2].utf8.allSatisfy({ $0 >= 32 && $0 < 127 }),
                fields[4].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                fields[4].utf8.count <= 19,
                let expiry = Int64(fields[4].isEmpty ? "0" : fields[4]), expiry >= 0
            else { throw SocialCookiesError.invalidFile }
            if expiry != 0 && Double(expiry) <= now.timeIntervalSince1970 { continue }
            var row = fields
            row[0] = domain
            row[4] = String(expiry)
            kept.append((httpOnly ? "#HttpOnly_" : "") + row.joined(separator: "\t"))
        }
        guard !kept.isEmpty else { throw SocialCookiesError.noCookies }
        contents = "# Netscape HTTP Cookie File\n" + kept.joined(separator: "\n") + "\n"
        count = kept.count
    }
}

/// A platform-neutral snapshot of a browser cookie. The iOS WebKit adapter creates
/// these records; keeping the export logic here makes it possible to test without WebKit.
public struct SocialBrowserCookie: Sendable {
    public let domain: String
    public let path: String
    public let name: String
    public let value: String
    public let expires: Date?
    public let secure: Bool
    public let httpOnly: Bool

    public init(
        domain: String, path: String, name: String, value: String,
        expires: Date?, secure: Bool, httpOnly: Bool
    ) {
        self.domain = domain
        self.path = path
        self.name = name
        self.value = value
        self.expires = expires
        self.secure = secure
        self.httpOnly = httpOnly
    }
}

extension SocialCookies {
    /// Converts only first-party browser cookies to a validated Netscape export.
    /// In particular, preserves HttpOnly, session-cookie, and Secure semantics,
    /// and never includes cookies from login-provider redirects or other sites.
    public init(browserCookies: [SocialBrowserCookie], platform: SocialPlatform, now: Date = Date()) throws {
        let prefix = "# Netscape HTTP Cookie File\n"
        var output = prefix
        for cookie in browserCookies {
            let domain = cookie.domain.lowercased()
            guard platform.acceptsCookieDomain(domain) else { continue }
            let path = cookie.path
            let name = cookie.name
            let value = cookie.value
            // Netscape cookies.txt is ASCII-delimited. Ignore unsupported rows,
            // rather than mangling credentials or saving a partial unsafe record.
            guard !name.isEmpty,
                name.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 59 && $0 != 61 }),
                value.utf8.allSatisfy({ $0 >= 32 && $0 < 127 && $0 != 59 }),
                path.hasPrefix("/"),
                path.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }),
                domain.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 })
            else { continue }
            let expiry: String
            if let expires = cookie.expires {
                let timestamp = expires.timeIntervalSince1970
                guard timestamp > now.timeIntervalSince1970,
                    timestamp.isFinite, timestamp < Double(Int64.max)
                else { continue }
                expiry = String(Int64(timestamp))
            } else {
                expiry = "0"  // Keep true browser session cookies as session cookies.
            }
            let subdomains = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let row =
                "\(cookie.httpOnly ? "#HttpOnly_" : "")\(domain)\t\(subdomains)\t\(path)\t\(cookie.secure ? "TRUE" : "FALSE")\t\(expiry)\t\(name)\t\(value)\n"
            guard output.utf8.count + row.utf8.count <= Self.maximumBytes else {
                throw SocialCookiesError.tooLarge
            }
            output += row
        }
        try self.init(data: Data(output.utf8), platform: platform, now: now)
    }
}
