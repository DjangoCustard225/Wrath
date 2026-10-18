import SwiftUI
import UniformTypeIdentifiers
import WrathCore

struct SocialAccessSettingsView: View {
    @State private var access = SocialAccessStore.shared
    var body: some View {
        Form {
            Section {
                ForEach(SocialPlatform.cookiePlatforms) { site in
                    NavigationLink {
                        SocialSiteSettingsView(site: site, access: access)
                    } label: {
                        LabeledContent(
                            site.name,
                            value: access.cookieCounts[site, default: 0] > 0 ? "Cookies saved" : "No cookies saved"
                        )
                    }
                    .accessibilityIdentifier("social-status-\(site.rawValue)")
                    .accessibilityLabel(site.name)
                    .accessibilityValue(
                        access.cookieCounts[site, default: 0] > 0 ? "Cookies saved" : "No cookies saved")
                }
            } footer: {
                Text(
                    "Sign in to Reddit inside Wrath or import a cookies.txt file. Cookies are stored securely on this device. Saved cookies do not confirm successful sign-in; retry a link to check access."
                )
            }
            Section {
                Link(
                    "yt-dlp cookie export guide",
                    destination: URL(
                        string: "https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp")!)
            } footer: {
                Text(
                    "Only export cookies you trust. Session cookies grant account access; never share the exported file. Login cannot bypass removed, private, regional, or DRM-protected media."
                )
            }
        }
        .navigationTitle("Cookies").navigationBarTitleDisplayMode(.inline)
    }
}

private struct SocialSiteSettingsView: View {
    let site: SocialPlatform
    @Bindable var access: SocialAccessStore
    @State private var importing = false
    @State private var signingIn = false
    @State private var reading = false
    @State private var removing = false
    @State private var clearing = false
    @State private var error: String?
    @State private var draftAgent = ""

    var body: some View {
        Form {
            Section("Reddit links") {
                Text(
                    "Open the post in a browser and copy its full URL from the address bar, containing /comments/. Copy the link from the browser, not the Reddit app; app share links may fail."
                )
                .accessibilityIdentifier("reddit-browser-link-note")
            }
            Section {
                LabeledContent(
                    "Saved cookies",
                    value: access.cookieCounts[site, default: 0] > 0
                        ? "\(access.cookieCounts[site, default: 0]) cookies saved" : "No cookies saved")
                Button {
                    signingIn = true
                } label: {
                    Label(
                        access.cookieCounts[site, default: 0] > 0 ? "Reconnect on website" : "Sign in on website",
                        systemImage: "person.crop.circle.badge.checkmark")
                }.disabled(reading || clearing)
                if let loadError = access.errors[site] {
                    Text(loadError).font(.footnote).foregroundStyle(.secondary)
                }
                Button(reading ? "Importing…" : "Import cookies.txt instead") { importing = true }
                    .disabled(reading || clearing)
                Button("Disconnect and clear browser login", role: .destructive) { removing = true }
                    .disabled(reading || clearing)
            } footer: {
                Text(
                    "Sign in through the official site and choose Save session once logged in. Wrath never reads your password. Alternatively, import a Netscape cookies.txt file. Only first-party \(site.name) cookies are saved; signing in may not be supported on all websites."
                )
            }
            Section {
                TextField("Default", text: $draftAgent, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("User-Agent")
                Button("Save User-Agent") {
                    do {
                        try access.saveUserAgent(draftAgent, for: site)
                        draftAgent = access.userAgents[site] ?? ""
                    } catch { self.error = error.localizedDescription }
                }.disabled(draftAgent == (access.userAgents[site] ?? ""))
                if access.userAgents[site] != nil {
                    Button("Use default User-Agent") {
                        draftAgent = ""
                        do { try access.saveUserAgent("", for: site) } catch { self.error = error.localizedDescription }
                    }
                }
            } header: {
                Text("User-Agent")
            } footer: {
                Text("Optional. Match the browser used to export your cookies, or leave blank for yt-dlp's default.")
            }
        }
        .navigationTitle(site.name).navigationBarTitleDisplayMode(.inline)
        .onAppear { draftAgent = access.userAgents[site] ?? "" }
        .sheet(isPresented: $signingIn) {
            SocialLoginView(site: site)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .data]) { result in
            switch result {
            case .success(let url): Task { await importFile(url) }
            case .failure: error = "Could not open the selected cookies.txt file."
            }
        }
        .confirmationDialog(
            "Delete saved \(site.name) cookies and in-app browser data?",
            isPresented: $removing, titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task {
                    clearing = true
                    defer { clearing = false }
                    do {
                        try access.removeCookies(for: site)
                        await SocialLoginBrowserProfile.clear(site)
                    } catch { self.error = error.localizedDescription }
                }
            }.accessibilityIdentifier("confirm-disconnect-social")
        }
        .alert(
            "Could not update cookies",
            isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )
        ) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func importFile(_ url: URL) async {
        reading = true
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            reading = false
        }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                return try handle.read(upToCount: SocialCookies.maximumBytes + 1) ?? Data()
            }.value
            try access.importCookies(data, for: site)
        } catch let failure as SocialCookiesError { error = failure.localizedDescription } catch {
            self.error = "Could not import cookies. Check that the file is available on this device."
        }
    }
}
