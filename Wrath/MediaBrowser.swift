import SwiftUI
import WebKit
import WrathCore

/// Built-in browser for finding downloadable media on a page, in the spirit of
/// download managers like 1DM+: browse normally, tap Grab media, and pick from
/// everything the scanner found. It uses its own default WebKit profile; the
/// social sign-in profiles are never touched.
@MainActor struct MediaBrowserView: View {
    @Bindable var store: DownloadStore
    /// Called after downloads were queued from the grab list.
    let started: () -> Void
    @State private var grabber: MediaGrabber
    @State private var webView: WKWebView
    @State private var address: String
    @State private var loading = true
    @State private var browserError: String?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var showingGrabList = false
    @FocusState private var addressFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private static let homePage = URL(string: "https://duckduckgo.com")!

    init(store: DownloadStore, started: @escaping () -> Void) {
        self.store = store
        self.started = started
        let grabber = MediaGrabber()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(MediaGrabber.userScript)
        configuration.userContentController.add(grabber, name: MediaGrabber.messageName)
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.allowsBackForwardNavigationGestures = true
        grabber.webView = browser
        _grabber = State(initialValue: grabber)
        _webView = State(initialValue: browser)
        _address = State(initialValue: Self.homePage.absoluteString)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar
                if let browserError {
                    VStack(spacing: 8) {
                        Text(browserError).font(.subheadline).foregroundStyle(.secondary)
                        Button("Reload") {
                            browserError = nil
                            loading = true
                            webView.reload()
                        }
                    }
                    .frame(maxWidth: .infinity).padding(16)
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 3) }
                MediaBrowserWebView(
                    webView: webView, grabber: grabber, loading: $loading,
                    address: $address, failure: $browserError,
                    canGoBack: $canGoBack, canGoForward: $canGoForward,
                    addressFocused: addressFocused, initialURL: Self.homePage
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Browse").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .wrathBottomBar { browserBar }
        }
        .sheet(isPresented: $showingGrabList) {
            GrabListView(grabber: grabber, store: store) {
                dismiss()
                started()
            }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
            TextField("Search or enter address", text: $address)
                .font(.subheadline)
                .keyboardType(.URL).textContentType(.URL)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($addressFocused).submitLabel(.go)
                .onSubmit(loadAddress)
            if loading {
                Button {
                    webView.stopLoading()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Stop loading")
            } else {
                Button {
                    webView.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Reload")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var browserBar: some View {
        HStack(spacing: 10) {
            Button {
                webView.goBack()
            } label: {
                Image(systemName: "chevron.backward").frame(width: 34, height: 34)
            }
            .disabled(!canGoBack)
            .accessibilityLabel("Back")
            Button {
                webView.goForward()
            } label: {
                Image(systemName: "chevron.forward").frame(width: 34, height: 34)
            }
            .disabled(!canGoForward)
            .accessibilityLabel("Forward")
            Spacer()
            Button {
                grabber.rescan()
                showingGrabList = true
            } label: {
                Label("Grab media", systemImage: "arrow.down.circle")
                    .font(.headline).frame(minHeight: 28)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
            .overlay(alignment: .topTrailing) {
                if !grabber.items.isEmpty {
                    Text("\(grabber.items.count)")
                        .font(.caption2.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.red, in: Capsule())
                        .offset(x: 6, y: -6)
                }
            }
            .accessibilityLabel(
                grabber.items.isEmpty
                    ? "Grab media" : "Grab media, \(grabber.items.count) found")
        }
        .frame(maxWidth: 600).frame(maxWidth: .infinity)
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func loadAddress() {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        addressFocused = false
        browserError = nil
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if scheme == "https" {
                webView.load(URLRequest(url: url))
                return
            }
            if scheme == "http",
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            {
                components.scheme = "https"
                if let upgraded = components.url {
                    webView.load(URLRequest(url: upgraded))
                    return
                }
            }
        }
        if !text.contains(where: { $0.isWhitespace }), text.contains("."),
            let url = URL(string: "https://" + text)
        {
            webView.load(URLRequest(url: url))
            return
        }
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        if let url = components.url { webView.load(URLRequest(url: url)) }
    }
}

@MainActor private struct MediaBrowserWebView: UIViewRepresentable {
    let webView: WKWebView
    let grabber: MediaGrabber
    @Binding var loading: Bool
    @Binding var address: String
    @Binding var failure: String?
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    let addressFocused: Bool
    let initialURL: URL

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        if webView.url == nil { webView.load(URLRequest(url: initialURL)) }
        return webView
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: MediaBrowserWebView
        init(_ parent: MediaBrowserWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
            parent.failure = nil
            parent.grabber.reset()
            updateNavigationState(webView)
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            updateNavigationState(webView)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            updateNavigationState(webView)
            parent.grabber.rescan()
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            showFailure(error)
        }
        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            showFailure(error)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.loading = false
            parent.failure = "The page stopped responding. Reload it to continue."
        }
        private func updateNavigationState(_ webView: WKWebView) {
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
            if !parent.addressFocused, let url = webView.url {
                parent.address = url.absoluteString
            }
        }
        private func showFailure(_ error: Error) {
            let failure = error as NSError
            // Redirects and replaced popup navigations routinely cancel a load.
            guard !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) else { return }
            parent.loading = false
            parent.failure = "The page could not load. Check your connection and reload it."
        }
        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Same policy as the sign-in browser: https pages only, and links
            // that ask for a new window load in place instead of being lost.
            guard let url = action.request.url,
                url.scheme?.lowercased() == "https" || url.scheme == "about"
            else {
                decisionHandler(.cancel)
                return
            }
            if action.targetFrame == nil {
                webView.load(action.request)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
