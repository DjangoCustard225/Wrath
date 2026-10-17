import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Keeps the system's explicit paste authorization while matching the link field.
struct CohesivePasteButton: UIViewRepresentable {
    let pasted: (String) -> Void
    final class PasteTarget: UIView {
        var pasted: (String) -> Void = { _ in }
        override init(frame: CGRect) {
            super.init(frame: frame)
            pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
                UTType.url.identifier, UTType.plainText.identifier,
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func paste(itemProviders: [NSItemProvider]) {
            guard let provider = itemProviders.first else { return }
            if provider.canLoadObject(ofClass: NSURL.self) {
                provider.loadObject(ofClass: NSURL.self) { [weak self] object, _ in
                    guard let url = object as? URL else { return }
                    Task { @MainActor in self?.pasted(url.absoluteString) }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                    guard let text = object as? String else { return }
                    Task { @MainActor in self?.pasted(text) }
                }
            }
        }
    }
    func makeUIView(context: Context) -> PasteTarget {
        let target = PasteTarget(frame: .zero)
        let config = UIPasteControl.Configuration()
        config.displayMode = .iconOnly
        config.cornerStyle = .capsule
        config.baseBackgroundColor = .tertiarySystemFill
        config.baseForegroundColor = .label
        let control = UIPasteControl(configuration: config)
        control.target = target
        control.accessibilityLabel = "Paste link"
        control.translatesAutoresizingMaskIntoConstraints = false
        target.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: target.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: target.trailingAnchor),
            control.topAnchor.constraint(equalTo: target.topAnchor),
            control.bottomAnchor.constraint(equalTo: target.bottomAnchor),
        ])
        target.pasted = pasted
        return target
    }
    func updateUIView(_ view: PasteTarget, context: Context) { view.pasted = pasted }
}
