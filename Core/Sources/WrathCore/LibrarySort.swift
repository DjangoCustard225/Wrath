import Foundation

public enum LibrarySort: String, CaseIterable, Sendable {
    case newest, oldest, title, largest, smallest
    public var label: String {
        switch self {
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .title: "Title A–Z"
        case .largest: "Largest first"
        case .smallest: "Smallest first"
        }
    }
    public func precedes(_ first: DownloadJob, _ second: DownloadJob) -> Bool {
        let firstDate = first.completed ?? first.created
        let secondDate = second.completed ?? second.created
        switch self {
        case .newest:
            if firstDate != secondDate { return firstDate > secondDate }
        case .oldest:
            if firstDate != secondDate { return firstDate < secondDate }
        case .title:
            let order = first.title.localizedStandardCompare(second.title)
            if order != .orderedSame { return order == .orderedAscending }
        case .largest:
            if first.bytes != second.bytes { return first.bytes > second.bytes }
        case .smallest:
            if first.bytes != second.bytes { return first.bytes < second.bytes }
        }
        // Stable tie breaking prevents equal dates/titles/sizes jumping around.
        if firstDate != secondDate { return firstDate > secondDate }
        return first.id.uuidString < second.id.uuidString
    }
}
