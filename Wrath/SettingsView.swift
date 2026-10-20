import SwiftUI
import WrathBridge
import WrathCore

struct SettingsView: View {
    @Bindable var store: DownloadStore
    private var usage: String? {
        store.storage.map { MediaLabels.bytes($0.savedBytes + $0.temporaryBytes + $0.cacheBytes) }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Downloads") {
                    Picker("Default format", selection: $store.kind) {
                        ForEach([MediaKind.video, .audio], id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
                Section {
                    NavigationLink {
                        SocialAccessSettingsView()
                    } label: {
                        Label("Cookies", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    NavigationLink {
                        AppLockSettingsView()
                    } label: {
                        Label("App Lock", systemImage: "lock")
                    }
                    NavigationLink {
                        StorageSettingsView(store: store)
                    } label: {
                        HStack {
                            Label("Storage", systemImage: "internaldrive")
                            Spacer()
                            if let usage {
                                Text(usage).foregroundStyle(.secondary)
                            } else if store.measuringStorage {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    NavigationLink {
                        AboutSettingsView()
                    } label: {
                        LabeledContent {
                            Text(AppVersion.release).foregroundStyle(.secondary)
                        } label: {
                            Label("About", systemImage: "info.circle")
                        }
                    }
                }
            }.navigationTitle("Settings")
                .task { await store.refreshStorage() }
        }
    }
}

private struct StorageSettingsView: View {
    @Bindable var store: DownloadStore
    @State private var confirmingCacheClear = false
    var body: some View {
        Form {
            Section {
                if let storage = store.storage {
                    LabeledContent("Saved files", value: MediaLabels.bytes(storage.savedBytes))
                    LabeledContent("Cache", value: MediaLabels.bytes(storage.cacheBytes))
                    LabeledContent("Temporary files", value: MediaLabels.bytes(storage.temporaryBytes))
                    if let available = storage.availableBytes {
                        LabeledContent("Available on device", value: MediaLabels.bytes(available))
                    }
                } else {
                    ProgressView("Measuring storage…")
                }
            } footer: {
                Text("Saved files are in Files › Wrath.")
            }
            Section {
                Button {
                    confirmingCacheClear = true
                } label: {
                    HStack {
                        Text(store.clearingCache ? "Clearing cache…" : "Clear cache")
                        if store.clearingCache {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }.disabled(store.clearingCache)
            } footer: {
                Text("Saved files and active downloads are kept.")
            }
        }.navigationTitle("Storage").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if store.measuringStorage {
                        ProgressView().controlSize(.small).accessibilityLabel("Refreshing storage")
                    } else {
                        Button("Refresh storage", systemImage: "arrow.clockwise") {
                            Task { await store.refreshStorage() }
                        }.disabled(store.clearingCache)
                    }
                }
            }
            .task { await store.refreshStorage() }
            .refreshable { await store.refreshStorage() }
            .confirmationDialog(
                "Clear cached thumbnails and extractor data?", isPresented: $confirmingCacheClear,
                titleVisibility: .visible
            ) {
                Button("Clear cache") { Task { await store.clearCaches() } }
                Button("Cancel", role: .cancel) {}
            }
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: AppVersion.full)
                LabeledContent(
                    "Build",
                    value: Bundle.main.infoDictionary?["WrathBuildVariant"] as? String == "compatibility"
                        ? "Compatibility · iOS 17+" : "Modern · iOS 26+")
                NavigationLink("Download help") { DownloadHelpView() }
            }
            Section("Components") {
                LabeledContent("yt-dlp", value: "2026.08.19")
                LabeledContent("FFmpeg", value: String(cString: wrath_ffmpeg_version()))
                LabeledContent("gallery-dl", value: "1.32.17")
            }
            Section {
                NavigationLink("Open-source licenses") { LicenseView().navigationBarTitleDisplayMode(.inline) }
                Link("SponsorBlock", destination: URL(string: "https://sponsor.ajay.app")!)
            }
        }.navigationTitle("About").navigationBarTitleDisplayMode(.inline)
    }
}

private struct DownloadHelpView: View {
    var body: some View {
        Form {
            Section("Options") {
                Text("Choose quality and media options after checking a link. Choices adjust to available tracks.")
            }
            Section("Downloads") {
                Text("One active download at a time.")
            }
            Section("Photo galleries") {
                Text("Paste a post, album, or image link. Up to 200 images; profiles and feeds aren't supported.")
            }
            Section("Background downloads") {
                if #available(iOS 26, *) {
                    Text("iOS may pause background work. Force-closing Wrath stops downloads; retry interrupted links.")
                } else {
                    Text("Keep Wrath open for long downloads. Retry links interrupted by iOS.")
                }
            }
            Section("Saved files") {
                Text("In Library, long-press a download to share, rename, or delete. Files › Wrath.")
            }
        }.navigationTitle("Download help").navigationBarTitleDisplayMode(.inline)
    }
}

private enum AppVersion {
    static var release: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    static var full: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "\(release) (\(build))"
    }
}
