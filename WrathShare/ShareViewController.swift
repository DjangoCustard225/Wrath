import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WrathCore

/// Wrath's share sheet entry: choose a format, then download now or finish choosing in Wrath.
@objc(WrathShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel()
        let host = UIHostingController(
            rootView: ShareOptionsView(
                model: model,
                open: { [weak self] text, preset in self?.handOff(text, preset: preset) },
                cancel: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { model.text = await sharedText() ?? "" }
    }

    private func handOff(_ text: String, preset: SharePreset) {
        if let url = LinkHandoff.appURL(for: text, preset: preset) { open(url) }
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Prefers a shared web link, then shared text such as a caption that contains one.
    private func sharedText() async -> String? {
        let providers = (extensionContext?.inputItems ?? []).compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
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

    /// Extensions have no supported API for opening their app. Like other share extensions, this finds the
    /// application in the responder chain and calls `open(_:options:completionHandler:)` through the runtime,
    /// since the method is unavailable to extension code at compile time.
    private func open(_ url: URL) {
        typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector), let method = current.method(for: selector) {
                unsafeBitCast(method, to: OpenURL.self)(current, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
    }
}

@Observable @MainActor private final class ShareModel {
    /// Nil while the shared item is loading.
    var text: String?
    var link: URL? { text.flatMap(LinkInput.parse) }
}

private struct ShareOptionsView: View {
    let model: ShareModel
    let open: (String, SharePreset) -> Void
    let cancel: () -> Void
    // The extension keeps its own last choice; Wrath's settings live in the app's container.
    @AppStorage("shareKind") private var kind = MediaKind.video
    @AppStorage("shareQuality") private var quality = Quality.fullHD.rawValue

    private static let qualities = [0, 2160, 1440, 1080, 720, 480]

    var body: some View {
        NavigationStack {
            Form {
                if let text = model.text, let link = model.link {
                    Section {
                        LabeledContent("Link", value: link.host() ?? link.absoluteString)
                    }
                    Section {
                        Picker("Save as", selection: $kind) {
                            Text("Video").tag(MediaKind.video)
                            Text("Audio").tag(MediaKind.audio)
                        }.pickerStyle(.segmented)
                        if kind == .video {
                            Picker("Quality", selection: $quality) {
                                ForEach(Self.qualities, id: \.self) { value in
                                    Text(Quality(rawValue: value)?.label ?? "").tag(value)
                                }
                            }
                        }
                    } footer: {
                        Text("Wrath uses the closest available quality. Photo posts download as galleries.")
                    }
                    Section {
                        Button {
                            open(text, preset(startNow: true))
                        } label: {
                            Label("Download Now", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                        Button("More Options in Wrath") { open(text, preset(startNow: false)) }
                            .frame(maxWidth: .infinity)
                    }
                } else if model.text == nil {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView(
                        "No link found", systemImage: "link.badge.plus",
                        description: Text("Share a web link, or text that contains one, to download it with Wrath."))
                }
            }
            .navigationTitle("Wrath").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) } }
        }
        .tint(.orange)
    }

    private func preset(startNow: Bool) -> SharePreset {
        SharePreset(kind: kind, quality: kind == .video ? Quality(rawValue: quality) : nil, startNow: startNow)
    }
}
