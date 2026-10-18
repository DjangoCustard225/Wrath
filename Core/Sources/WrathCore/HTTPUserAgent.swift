import Foundation

public enum HTTPUserAgentError: LocalizedError {
    case invalid
    public var errorDescription: String? {
        "Enter a User-Agent of at most 1,024 characters, without line breaks or control characters."
    }
}

public enum HTTPUserAgent {
    public static func validated(_ text: String) throws -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 1024, value.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else {
            throw HTTPUserAgentError.invalid
        }
        return value.isEmpty ? nil : value
    }
}
