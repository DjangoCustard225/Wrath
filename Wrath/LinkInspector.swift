import Foundation
import WrathCore

struct LinkInspectionRequest: Hashable {
    let url: URL?
    let revision: Int
}

extension LinkInspector {
    convenience init() {
        self.init { url in
            let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Wrath/ExtractorCache", isDirectory: true)
            return try await MediaEngine.shared.inspect(url: url, cache: cache, token: OperationToken())
        }
    }
}
