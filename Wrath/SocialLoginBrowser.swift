import Foundation
import SwiftUI
import WebKit
import WrathCore

/// One persistent WebKit profile per social service. Cookies in these profiles
/// are never read from Safari or from other installed applications.
@MainActor enum SocialLoginBrowserProfile {
    private static let identifiers: [SocialPlatform: UUID] = [
        .instagram: UUID(uuidString: "AB550001-1000-4000-8000-000000000001")!,
        .tiktok: UUID(uuidString: "AB550001-1000-4000-8000-000000000002")!,
        .facebook: UUID(uuidString: "AB550001-1000-4000-8000-000000000003")!,
        .x: UUID(uuidString: "AB550001-1000-4000-8000-000000000004")!,
        .reddit: UUID(uuidString: "AB550001-1000-4000-8000-000000000005")!,
        .threads: UUID(uuidString: "AB550001-1000-4000-8000-000000000006")!,
    ]

    static func store(for site: SocialPlatform) -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: identifiers[site]!)
    }

    static func clear(_ site: SocialPlatform) async {
        let store = store(for: site)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
    }
}

extension SocialPlatform {
    fileprivate var loginURL: URL {
        let address: String
        switch self {
        case .instagram: address = "https://www.instagram.com/accounts/login/"
        case .tiktok: address = "https://www.tiktok.com/login"
        case .facebook: address = "https://www.facebook.com/login/"
        case .x: address = "https://x.com/i/flow/login"
        case .reddit: address = "https://www.reddit.com/login/"
        case .threads: address = "https://www.threads.com/login"
        }
        return URL(string: address)!
    }
}

/// Visible, user-controlled sign-in browser. Only native WebKit cookie APIs are
/// used: no password/DOM scraping, traffic interception, or third-party logins.
@MainActor struct SocialLoginView: View {
    let site: SocialPlatform
    @State private var webView: WKWebView
    @State private var currentHost: String?
    @State private var loading = true
    @State private var browserError: String?
    @State private var saving = false
    @State private var error: String?
    @State private var success = false
    @Environment(\.dismiss) private var dismiss

    init(site: SocialPlatform) {
        self.site = site
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = SocialLoginBrowserProfile.store(for: site)
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.allowsBackForwardNavigationGestures = true
        _webView = State(initialValue: browser)
        _currentHost = State(initialValue: site.loginURL.host)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign in to \(site.name) on its website, then tap Save session.")
                        .font(.subheadline)
                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield")
                        Text(currentHost ?? site.loginURL.host ?? "Website")
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let host = currentHost,
                        !site.domains.contains(where: { host == $0 || host.hasSuffix("." + $0) })
                    {
                        Text("You are on an external sign-in domain. Check the address before entering credentials.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
                if let browserError {
                    VStack(spacing: 8) {
                        Text(browserError).font(.subheadline).foregroundStyle(.secondary)
                        Button("Reload sign-in") {
                            self.browserError = nil
                            loading = true
                            webView.load(URLRequest(url: site.loginURL))
                        }
                    }
                    .frame(maxWidth: .infinity).padding(16)
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 3) }
                SocialLoginWebView(
                    webView: webView, loading: $loading, host: $currentHost,
                    failure: $browserError, initialURL: site.loginURL
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Button {
                    Task { await saveSession() }
                } label: {
                    if saving {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 28)
                    } else {
                        Label("Save session", systemImage: "checkmark.shield")
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .controlSize(.large).disabled(saving || loading || browserError != nil)
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Connect \(site.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
            }
        }
        .alert(
            success ? "Cookies saved" : "Could not save session",
            isPresented: Binding(
                get: { success || error != nil },
                set: {
                    if !$0 {
                        success = false
                        error = nil
                    }
                }
            )
        ) {
            Button(success ? "Done" : "OK") {
                if success { dismiss() } else { error = nil }
            }
        } message: {
            Text(
                success
                    ? "Wrath saved these \(site.name) cookies. Retry your link to check access; saving cookies does not confirm that sign-in succeeded."
                    : (error ?? ""))
        }
    }

    private func saveSession() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        // CookieStore includes HttpOnly cookies, unlike JavaScript document.cookie.
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
        let userAgent = (try? await webView.evaluateJavaScript("navigator.userAgent")) as? String
        do {
            try SocialAccessStore.shared.saveBrowserCookies(cookies, for: site, userAgent: userAgent)
            success = true
        } catch let failure as SocialCookiesError {
            error = failure.localizedDescription + " Finish signing in on the website, then try again."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor private struct SocialLoginWebView: UIViewRepresentable {
    let webView: WKWebView
    @Binding var loading: Bool
    @Binding var host: String?
    @Binding var failure: String?
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
        var parent: SocialLoginWebView
        init(_ parent: SocialLoginWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
            parent.failure = nil
            parent.host = webView.url?.host
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            parent.host = webView.url?.host
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.host = webView.url?.host
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
            parent.failure = "The sign-in page stopped responding. Reload it to continue."
        }
        private func showFailure(_ error: Error) {
            let failure = error as NSError
            // Redirects and replaced popup navigations routinely cancel a load.
            guard !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) else { return }
            parent.loading = false
            parent.failure = "The sign-in page could not load. Check your connection and reload it."
        }
        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Prevent unknown/custom schemes from leaving the embedded sign-in.
            guard let url = action.request.url,
                url.scheme?.lowercased() == "https" || url.scheme == "about"
            else {
                decisionHandler(.cancel)
                return
            }
            if action.targetFrame == nil {
                // OAuth flows often open a new tab. Keep it in the same visible
                // login browser instead of silently losing the redirect.
                webView.load(action.request)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
