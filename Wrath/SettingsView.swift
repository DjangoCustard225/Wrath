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
                        ForEach(MediaKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
                Section {
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
    private var historyCount: Int { store.queue.filter { [.failed, .cancelled].contains($0.job.state) }.count }
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
                Text("Find saved files in Files › Wrath.")
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
                Text("Keeps saved files and active downloads.")
            }
            if historyCount > 0 {
                Section("Download history") {
                    Button {
                        store.clearFinishedQueue()
                    } label: {
                        HStack {
                            Text("Clear failed & cancelled entries")
                            Spacer()
                            Text("\(historyCount)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
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
                NavigationLink("Download help") { DownloadHelpView() }
            }
            Section("Components") {
                LabeledContent("yt-dlp", value: "2026.08.19")
                LabeledContent("FFmpeg", value: String(cString: wrath_ffmpeg_version()))
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
                Text(
                    "Choose quality, codecs, thumbnails, and subtitles when adding a link. Wrath remembers your choices and adjusts them to the available tracks."
                )
            }
            Section("Queue") {
                Text(
                    "Downloads run one at a time. Pause after current lets the active download finish before pausing the queue."
                )
            }
            Section("Background downloads") {
                Text(
                    "Keep Wrath open for long downloads. iOS limits background time; if a download is interrupted, open it in Downloads and retry."
                )
            }
            Section("Saved files") {
                Text(
                    "Find your downloads in Library or Files › Wrath. Long-press a Library item to share, rename, or delete it."
                )
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
