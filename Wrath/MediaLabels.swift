import Foundation

enum MediaLabels {
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    static func duration(_ value: Double?) -> String? {
        guard let value, value.isFinite, value > 0, value < 1e9 else { return nil }
        let seconds = Int(value)
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    static func shortETA(_ value: Double) -> String? {
        guard value.isFinite, value > 0, value < 1e9 else { return nil }
        if value < 60 { return "< 1 min" }
        if value < 3600 { return "≈ \(Int(ceil(value / 60))) min" }
        return "≈ \(Int(ceil(value / 3600))) hr"
    }
    static func codec(_ value: String) -> String {
        switch value {
        case "h264": "H.264"
        case "hevc": "HEVC (H.265)"
        case "av1": "AV1"
        case "vp9": "VP9"
        default: value.uppercased()
        }
    }
}
