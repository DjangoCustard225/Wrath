import UIKit
import UniformTypeIdentifiers
import WrathCore

/// Wrath's share sheet entry: hands the shared link to the app, which opens on its add-link screen.
@objc(WrathShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await handOff() }
    }

    private func handOff() async {
        let providers = (extensionContext?.inputItems ?? []).compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
        if let text = await sharedText(from: providers), let url = LinkHandoff.appURL(for: text) {
            open(url)
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Prefers a shared web link, then shared text such as a caption that contains one.
    private func sharedText(from providers: [NSItemProvider]) async -> String? {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await load(URL.self, from: provider), !url.isFileURL { return url.absoluteString }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await load(String.self, from: provider) { return text }
        }
        return nil
    }

    private func load<Value: Transferable & Sendable>(_ type: Value.Type, from provider: NSItemProvider) async
        -> Value?
    {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: type) { continuation.resume(returning: try? $0.get()) }
        }
    }

    /// Extensions have no supported API for opening their app, so this reaches the application through the
    /// responder chain, as share extensions commonly do.
    private func open(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url)
                return
            }
            responder = current.next
        }
    }
}
