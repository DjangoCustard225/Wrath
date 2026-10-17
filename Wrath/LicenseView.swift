import SwiftUI

struct LicenseView: View {
    private var files: [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: Bundle.main.bundleURL.appendingPathComponent("Licenses"), includingPropertiesForKeys: nil))?.sorted {
                $0.lastPathComponent < $1.lastPathComponent
            } ?? []
    }
    var body: some View {
        List(files, id: \.self) { file in
            NavigationLink(file.deletingPathExtension().lastPathComponent) {
                ScrollView {
                    Text((try? String(contentsOf: file, encoding: .utf8)) ?? "License unavailable.").font(.caption)
                        .textSelection(.enabled).padding()
                }
                .navigationTitle(file.deletingPathExtension().lastPathComponent).navigationBarTitleDisplayMode(.inline)
            }
        }.navigationTitle("Licenses")
    }
}
