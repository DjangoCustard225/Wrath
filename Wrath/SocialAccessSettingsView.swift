import SwiftUI
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
                    "Sign in on the website. Cookies stay securely on this device; sign-in does not guarantee access."
                )
            }

        }
        .navigationTitle("Cookies").navigationBarTitleDisplayMode(.inline)
    }
}

private struct SocialSiteSettingsView: View {
    let site: SocialPlatform
    @Bindable var access: SocialAccessStore
    @State private var signingIn = false
    @State private var removing = false
    @State private var clearing = false
    @State private var error: String?

    var body: some View {
        Form {
            if site == .reddit {
                Section("Reddit links") {
                    Text("Open the post in a browser and copy its full /comments/ URL. Reddit app links may fail.")
                        .accessibilityIdentifier("reddit-browser-link-note")
                }
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
                }.disabled(clearing)
                if let loadError = access.errors[site] {
                    Text(loadError).font(.footnote).foregroundStyle(.secondary)
                }
                Button("Disconnect and clear browser login", role: .destructive) { removing = true }
                    .disabled(clearing)
            } footer: {
                Text(
                    "Sign in on the official website, then tap Save session."
                )
            }
        }
        .navigationTitle(site.name).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $signingIn) {
            SocialLoginView(site: site)
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

}
