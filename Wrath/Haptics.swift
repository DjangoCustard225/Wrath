import UIKit

/// Feedback for moments that happen away from a control, such as a download finishing.
@MainActor enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func failure() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func started() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
}
