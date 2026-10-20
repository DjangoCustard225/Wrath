import QuickLook
import SwiftUI

struct FilePreview: UIViewControllerRepresentable {
    let url: URL
    var additionalURLs: [URL] = []
    var selectedIndex = 0
    @Environment(\.dismiss) private var dismiss
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let urls: [URL]
        init(urls: [URL]) { self.urls = urls }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            urls[index] as NSURL
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(urls: [url] + additionalURLs) }
    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.currentPreviewItemIndex = min(max(0, selectedIndex), context.coordinator.urls.count - 1)
        preview.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { _ in dismiss() })
        return UINavigationController(rootViewController: preview)
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}
