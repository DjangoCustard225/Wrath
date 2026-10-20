import Foundation

public struct TransferPresentation: Sendable {
    public let received: Int64
    public let total: Int64?
    public let speed: Double
    public let eta: Double?
    public var fraction: Double? {
        total.flatMap { $0 > 0 ? min(1, Double(received) / Double($0)) : nil }
    }
}

/// Five-second rolling speed; ETA needs two seconds of real transfer samples.
public struct TransferPresentationMeter {
    private var samples: [(time: Double, bytes: Int64)] = []
    public init() {}
    public mutating func sample(bytes: Int64, total: Int64?, time: Double) -> TransferPresentation {
        if let last = samples.last, time < last.time || bytes < last.bytes { samples.removeAll() }
        samples.append((time, max(0, bytes)))
        while samples.count > 2 && samples[1].time <= time - 5 { samples.removeFirst() }
        let first = samples[0]
        let elapsed = time - first.time
        let speed = elapsed >= 1 ? Double(max(0, bytes - first.bytes)) / elapsed : 0
        let knownTotal = total.flatMap { $0 > 0 ? $0 : nil }
        let eta = knownTotal.flatMap { elapsed >= 2 && speed > 1 && bytes < $0 ? Double($0 - bytes) / speed : nil }
        return TransferPresentation(received: max(0, bytes), total: knownTotal, speed: speed, eta: eta)
    }
}

public enum ProcessingPhase: Int32, Sendable {
    case preparing = 0
    case cutting, subtitles, artwork, copying, finalizing, saving
    public var label: String {
        switch self {
        case .preparing: "Preparing file"
        case .cutting: "Preparing cuts"
        case .subtitles: "Preparing subtitles"
        case .artwork: "Embedding thumbnail"
        case .copying: "Writing media"
        case .finalizing: "Finalizing file"
        case .saving: "Saving file"
        }
    }
}

public enum DownloadWarnings {
    /// Extractor diagnostics do not mean a successfully saved gallery is incomplete.
    /// Apply this to persisted jobs too, so old galleries lose the generic warning.
    public static func visible(_ warning: String?, for kind: MediaKind) -> String? {
        guard let warning, !warning.isEmpty else { return nil }
        guard kind == .images else { return warning }
        let skipped = "Saved images only; video or unsupported linked attachments were not included."
        return warning.contains(skipped) ? skipped : nil
    }

    public static func appending(_ warning: String, to current: String?) -> String {
        var parts = (current ?? "").components(separatedBy: " · ").filter { !$0.isEmpty }
        if !parts.contains(warning) { parts.append(warning) }
        return parts.joined(separator: " · ")
    }
    public static func summary(_ warning: String) -> String {
        if warning.contains("Saved images only;") { return "Images only" }
        var missing: [String] = []
        if warning.contains("Saved without thumbnail") { missing.append("thumbnail") }
        if warning.contains("Saved without subtitles") { missing.append("subtitles") }
        return missing.isEmpty ? "Saved with a warning" : "Saved without " + missing.joined(separator: " and ")
    }
}
