import Foundation

/// Library search: every word must appear in the title, author, source site or file name.
public enum LibrarySearch {
    public static func matches(_ job: DownloadJob, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let fields = [job.title, job.author, job.sourceURL.host() ?? "", job.filename ?? ""]
        return words.allSatisfy { word in
            fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
