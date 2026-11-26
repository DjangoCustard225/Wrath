import ActivityKit
import Foundation

/// The Lock Screen and Dynamic Island activity for the one running download.
public struct DownloadActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        /// The media title, or a private title while App Lock is on.
        public var title: String
        /// What is happening, such as "Downloading · 42% · 3 MB/s".
        public var status: String
        /// From 0 to 1, or nil while the size is unknown.
        public var fraction: Double?
        public var finished: Bool

        public init(title: String, status: String, fraction: Double?, finished: Bool = false) {
            self.title = title
            self.status = status
            self.fraction = fraction.map { min(1, max(0, $0)) }
            self.finished = finished
        }
    }

    public init() {}
}
