import QuickLook
import SwiftUI

struct FilePreview: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { _ in dismiss() })
        return UINavigationController(rootViewController: preview)
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}
