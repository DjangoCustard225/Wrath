import Foundation

public enum AppSheet: Equatable, Identifiable, Sendable {
    case addLink
    case retryLink(URL)
    case download(UUID)
    case redditLogin
    case browser
    public var id: String {
        switch self {
        case .addLink: "add-link"
        case .retryLink(let url): "retry-link-" + url.absoluteString
        case .download(let id): "download-" + id.uuidString
        case .redditLogin: "reddit-login"
        case .browser: "browser"
        }
    }
}

/// Hand off native sheets only after the outgoing sheet has finished dismissing.
public struct AppSheetPresentation: Sendable {
    public private(set) var sheet: AppSheet?
    public private(set) var isDismissing = false
    private var pending: AppSheet?
    private var activeDownload: UUID?
    public init() {}

    public mutating func present(_ sheet: AppSheet) {
        guard self.sheet != sheet else { return }
        if self.sheet != nil || isDismissing {
            pending = sheet
            dismiss()
        } else {
            self.sheet = sheet
        }
    }
    public mutating func dismiss() {
        guard sheet != nil else { return }
        sheet = nil
        isDismissing = true
    }
    public mutating func didDismiss() {
        isDismissing = false
        sheet = pending
        pending = nil
    }
    public mutating func downloadChanged(_ id: UUID?) {
        guard id != activeDownload else { return }
        activeDownload = id
        if let id {
            present(.download(id))
        } else {
            if case .download = pending { pending = nil }
            if case .download = sheet { dismiss() }
        }
    }
}
