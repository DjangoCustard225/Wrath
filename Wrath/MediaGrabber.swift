import Foundation
import Observation
import WebKit
import WrathCore

/// Kinds of media the built-in browser can grab from a page.
enum GrabKind: String, CaseIterable, Identifiable, Sendable {
    case video, audio, image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Images"
        }
    }

    var systemImage: String {
        switch self {
        case .video: "film"
        case .audio: "music.note"
        case .image: "photo"
        }
    }

    /// The download kind handed to DownloadStore, mirroring the choice the
    /// Add Link sheet would resolve to. Images keep the store's current kind:
    /// a grabbed image is a direct file, not a gallery post.
    var downloadKind: MediaKind? {
        switch self {
        case .video: .video
        case .audio: .audio
        case .image: nil
        }
    }
}

/// One downloadable file found on a web page by the media scanner.
struct GrabbedMedia: Identifiable, Equatable, Sendable {
    let url: URL
    let kind: GrabKind
    /// Extra context from the page, e.g. a video's resolution.
    let label: String
    var size: Int64?
    var sizeResolved = false

    var id: URL { url }

    var filename: String {
        let name = url.lastPathComponent
        return name.isEmpty ? (url.host ?? url.absoluteString) : name
    }

    var detail: String {
        var parts: [String] = []
        if !label.isEmpty { parts.append(label) }
        if let host = url.host { parts.append(host) }
        return parts.joined(separator: " · ")
    }
}

/// Collects media candidates posted by the scanner script running in the
/// built-in browser, dedupes them, tracks the user's selection, and resolves
/// file sizes in the background.
@MainActor @Observable final class MediaGrabber: NSObject {
    private(set) var items: [GrabbedMedia] = []
    /// Media elements the page plays through blob: URLs (streaming players).
    /// Those bytes never exist at a downloadable address, so they are counted
    /// and explained in the UI instead of listed.
    private(set) var blobCount = 0
    private(set) var selected: Set<URL> = []

    @ObservationIgnored private var seen: Set<URL> = []
    @ObservationIgnored weak var webView: WKWebView?

    static let messageName = "wrathMedia"

    static var userScript: WKUserScript {
        WKUserScript(source: scannerSource, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
    }

    var selectedItems: [GrabbedMedia] { items.filter { selected.contains($0.url) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + ($1.size ?? 0) } }
    var selectedBytesKnown: Bool { !selectedItems.isEmpty && selectedItems.allSatisfy { $0.size != nil } }

    func items(of kind: GrabKind) -> [GrabbedMedia] { items.filter { $0.kind == kind } }
    func isSelected(_ item: GrabbedMedia) -> Bool { selected.contains(item.url) }
    func toggle(_ item: GrabbedMedia) {
        if selected.contains(item.url) {
            selected.remove(item.url)
        } else {
            selected.insert(item.url)
        }
    }
    func selectAll() { selected = Set(items.map(\.url)) }
    func selectNone() { selected = [] }

    /// A new page started loading: everything found so far belongs to the old one.
    func reset() {
        items = []
        seen = []
        selected = []
        blobCount = 0
    }

    /// Ask the scanner in the page to run again (after load, or on demand).
    func rescan() {
        webView?.evaluateJavaScript("window.__wrathRescan && window.__wrathRescan();", completionHandler: nil)
    }

    func receive(body: Any) {
        guard let body = body as? [String: Any] else { return }
        if let blobs = body["blobCount"] as? Int { blobCount = max(blobCount, blobs) }
        let rawItems = body["items"] as? [[String: Any]] ?? []
        var added: [GrabbedMedia] = []
        for raw in rawItems {
            guard let text = raw["url"] as? String, var url = URL(string: text) else { continue }
            // Match the app's https-only web policy: upgrade plain http
            // candidates instead of dropping them outright.
            if url.scheme?.lowercased() == "http",
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            {
                components.scheme = "https"
                if let upgraded = components.url { url = upgraded }
            }
            guard url.scheme?.lowercased() == "https", !seen.contains(url) else { continue }
            seen.insert(url)
            let kind = GrabKind(rawValue: raw["kind"] as? String ?? "") ?? .video
            let item = GrabbedMedia(url: url, kind: kind, label: raw["label"] as? String ?? "")
            items.append(item)
            // Video and audio start selected; images are opt-in so a page full
            // of photos does not flood the download queue by accident.
            if kind != .image { selected.insert(url) }
            added.append(item)
        }
        if !added.isEmpty { probeSizes(for: added) }
    }

    private func probeSizes(for newItems: [GrabbedMedia]) {
        let urls = newItems.map(\.url)
        Task {
            var index = 0
            while index < urls.count {
                let batch = Array(urls[index..<min(index + 8, urls.count)])
                index += batch.count
                let results = await withTaskGroup(of: (URL, Int64?).self) { group in
                    for url in batch {
                        group.addTask { (url, await MediaSizeResolver.shared.resolve(url)) }
                    }
                    var collected: [(URL, Int64?)] = []
                    for await result in group { collected.append(result) }
                    return collected
                }
                for (url, size) in results {
                    if let position = items.firstIndex(where: { $0.url == url }) {
                        items[position].size = size
                        items[position].sizeResolved = true
                    }
                }
            }
        }
    }

    /// Scanner injected into every frame of the built-in browser. It collects
    /// media elements, links to media files, large images, and resources the
    /// page actually loaded, dedupes them, and posts new finds to Swift.
    private static let scannerSource = #"""
        (function () {
          'use strict';
          if (window.__wrathGrabber) { window.__wrathRescan(); return; }
          var VIDEO_EXTS = ['mp4', 'mkv', 'webm', 'mov', 'm4v', 'avi', 'ts', 'm3u8'];
          var AUDIO_EXTS = ['mp3', 'm4a', 'aac', 'ogg', 'opus', 'flac', 'wav'];
          var IMAGE_EXTS = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'avif'];
          var seen = {};
          var blobURLs = {};
          var blobTotal = 0;
          var blobSent = 0;

          function extensionOf(url) {
            try {
              var path = new URL(url, document.baseURI).pathname.toLowerCase();
              var dot = path.lastIndexOf('.');
              return dot >= 0 ? path.slice(dot + 1) : '';
            } catch (error) { return ''; }
          }
          function kindForExtension(url) {
            var ext = extensionOf(url);
            if (VIDEO_EXTS.indexOf(ext) >= 0) return 'video';
            if (AUDIO_EXTS.indexOf(ext) >= 0) return 'audio';
            if (IMAGE_EXTS.indexOf(ext) >= 0) return 'image';
            return null;
          }
          function scan() {
            var found = [];
            function add(raw, hint, label, needExtension) {
              if (!raw) return;
              var absolute;
              try { absolute = new URL(raw, document.baseURI).href; } catch (error) { return; }
              if (absolute.indexOf('blob:') === 0) {
                if (!blobURLs[absolute]) { blobURLs[absolute] = true; blobTotal += 1; }
                return;
              }
              if (absolute.indexOf('https://') !== 0 && absolute.indexOf('http://') !== 0) return;
              if (seen[absolute]) return;
              var kind = kindForExtension(absolute);
              if (!kind) {
                if (needExtension) return;
                kind = hint;
              }
              if (!kind) return;
              seen[absolute] = true;
              found.push({ url: absolute, kind: kind, label: label || '' });
            }
            var videos = document.querySelectorAll('video');
            for (var i = 0; i < videos.length; i++) {
              var video = videos[i];
              var label = video.videoWidth && video.videoHeight
                ? video.videoWidth + '×' + video.videoHeight : '';
              add(video.currentSrc || video.src, 'video', label, false);
              if (video.poster) add(video.poster, 'image', '', false);
              var vsources = video.querySelectorAll('source');
              for (var j = 0; j < vsources.length; j++) add(vsources[j].src, 'video', '', false);
            }
            var audios = document.querySelectorAll('audio');
            for (var a = 0; a < audios.length; a++) {
              add(audios[a].currentSrc || audios[a].src, 'audio', '', false);
              var asources = audios[a].querySelectorAll('source');
              for (var s = 0; s < asources.length; s++) add(asources[s].src, 'audio', '', false);
            }
            var links = document.querySelectorAll('a[href]');
            for (var l = 0; l < links.length; l++) add(links[l].href, null, '', true);
            var images = document.querySelectorAll('img');
            for (var m = 0; m < images.length; m++) {
              var image = images[m];
              if ((image.naturalWidth || 0) < 300) continue;
              var best = image.currentSrc || image.src;
              if (image.srcset) {
                var widest = 0;
                var parts = image.srcset.split(',');
                for (var p = 0; p < parts.length; p++) {
                  var bits = parts[p].trim().split(/\s+/);
                  var width = 0;
                  if (bits.length > 1 && /^\d+w$/.test(bits[1])) width = parseInt(bits[1], 10);
                  if (bits[0] && width > widest) { widest = width; best = bits[0]; }
                }
              }
              var dims = image.naturalWidth && image.naturalHeight
                ? image.naturalWidth + '×' + image.naturalHeight : '';
              add(best, 'image', dims, false);
            }
            try {
              var entries = performance.getEntriesByType('resource');
              for (var r = 0; r < entries.length; r++) {
                var entry = entries[r];
                var hint = null;
                var needExt = true;
                if (entry.initiatorType === 'video') { hint = 'video'; needExt = false; }
                else if (entry.initiatorType === 'audio') { hint = 'audio'; needExt = false; }
                add(entry.name, hint, '', needExt);
              }
            } catch (error) {}
            if (found.length > 0 || blobTotal !== blobSent) {
              blobSent = blobTotal;
              try {
                window.webkit.messageHandlers.wrathMedia.postMessage({ items: found, blobCount: blobTotal });
              } catch (error) {}
            }
          }
          window.__wrathRescan = scan;
          window.__wrathGrabber = true;
          var timer = null;
          var observer = new MutationObserver(function () {
            if (timer) return;
            timer = setTimeout(function () { timer = null; scan(); }, 700);
          });
          function startObserving() {
            if (document.documentElement) {
              observer.observe(document.documentElement, {
                childList: true, subtree: true, attributes: true,
                attributeFilter: ['src', 'href', 'poster', 'srcset']
              });
            }
          }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', function () { scan(); startObserving(); });
          } else {
            scan();
            startObserving();
          }
          window.addEventListener('load', scan);
          setInterval(scan, 5000);
        })();
        """#
}

extension MediaGrabber: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageName else { return }
        let body = message.body
        Task { @MainActor in self.receive(body: body) }
    }
}

/// Resolves a remote file's size without downloading it: a HEAD request, and
/// when that fails or reports no length, a ranged GET whose transfer is
/// cancelled as soon as the response headers arrive.
final class MediaSizeResolver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = MediaSizeResolver()

    private var session: URLSession!
    private var completions: [Int: (Int64?) -> Void] = [:]
    private let lock = NSLock()

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func resolve(_ url: URL) async -> Int64? {
        if let size = await probe(url, method: "HEAD") { return size }
        return await probe(url, method: "GET")
    }

    private func probe(_ url: URL, method: String) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15"
                + " (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")
        if method == "GET" { request.setValue("bytes=0-0", forHTTPHeaderField: "Range") }
        return await withCheckedContinuation { continuation in
            let task = session.dataTask(with: request)
            lock.lock()
            completions[task.taskIdentifier] = { size in continuation.resume(returning: size) }
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        finish(dataTask.taskIdentifier, size: Self.size(from: response))
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(task.taskIdentifier, size: nil)
    }

    private func finish(_ taskIdentifier: Int, size: Int64?) {
        lock.lock()
        let completion = completions.removeValue(forKey: taskIdentifier)
        lock.unlock()
        completion?(size)
    }

    private static func size(from response: URLResponse) -> Int64? {
        guard let http = response as? HTTPURLResponse,
            http.statusCode == 200 || http.statusCode == 206
        else { return nil }
        // A 206 answers the ranged GET: Content-Range ends with the full size.
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
            let total = range.split(separator: "/").last, let value = Int64(total), value > 0
        {
            return value
        }
        return response.expectedContentLength > 0 ? response.expectedContentLength : nil
    }
}

/// DownloadStore runs one download at a time, so grabbed links wait here and
/// are handed over one by one as the store frees up — the same result as a
/// user adding the links by hand, one after another.
@MainActor final class GrabDownloadQueue {
    static let shared = GrabDownloadQueue()

    private var pending: [GrabbedMedia] = []
    private var task: Task<Void, Never>?

    private init() {}

    func enqueue(_ media: [GrabbedMedia], store: DownloadStore) {
        pending.append(contentsOf: media)
        guard task == nil else { return }
        task = Task { await drain(store: store) }
    }

    private func drain(store: DownloadStore) async {
        while true {
            if Task.isCancelled || pending.isEmpty {
                task = nil
                return
            }
            let next = pending[0]
            if store.canAddDownload {
                pending.removeFirst()
                if let kind = next.kind.downloadKind { store.kind = kind }
                if !store.add(next.url) {
                    // Lost a race with another add; put it back and wait.
                    pending.insert(next, at: 0)
                    try? await Task.sleep(for: .milliseconds(300))
                }
            } else {
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}
