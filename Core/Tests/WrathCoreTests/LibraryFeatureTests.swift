import Foundation
import Testing

@testable import WrathCore

@Suite struct LibrarySearchTests {
    private func job(title: String, author: String = "", url: String = "https://www.youtube.com/watch?v=a")
        -> DownloadJob
    {
        var job = DownloadJob(url: URL(string: url)!, kind: .video, quality: .best, options: DownloadOptions())
        job.title = title
        job.author = author
        job.filename = title + ".mp4"
        return job
    }

    @Test func matchesEveryWordAcrossFields() {
        let video = job(title: "Café Tour", author: "Night Owl")
        #expect(LibrarySearch.matches(video, query: ""))
        #expect(LibrarySearch.matches(video, query: "cafe"))
        #expect(LibrarySearch.matches(video, query: "owl tour"))
        #expect(LibrarySearch.matches(video, query: "youtube"))
        #expect(!LibrarySearch.matches(video, query: "owl reddit"))
    }
}

@Suite struct PhotoLibraryCompatibilityTests {
    @Test func acceptsPhotosAndAppleVideoContainers() {
        #expect(PhotoLibraryCompatibility.resource(forFilename: "a.MP4") == .video)
        #expect(PhotoLibraryCompatibility.resource(forFilename: "a.heic") == .photo)
        #expect(PhotoLibraryCompatibility.resource(forFilename: "a.mkv") == nil)
        #expect(PhotoLibraryCompatibility.resource(forFilename: "a.m4a") == nil)
    }

    @Test func onlyOffersSavingForCompatibleDownloads() {
        var video = DownloadJob(
            url: URL(string: "https://example.com")!, kind: .video, quality: .best, options: DownloadOptions())
        video.state = .completed
        video.filename = "clip.mp4"
        #expect(PhotoLibraryCompatibility.canSave(video))
        video.filename = "clip.mkv"
        #expect(!PhotoLibraryCompatibility.canSave(video))
        var audio = video
        audio.kind = .audio
        audio.filename = "song.m4a"
        #expect(!PhotoLibraryCompatibility.canSave(audio))
        var gallery = video
        gallery.kind = .images
        gallery.galleryFiles = [GalleryFile(filename: "1.jpg", bytes: 1)]
        #expect(PhotoLibraryCompatibility.canSave(gallery))
    }
}

@Suite struct DownloadNoticeTests {
    @Test func namesTheMediaOnlyWithoutAppLock() {
        let open = DownloadNotice(state: .completed, mediaTitle: "Clip", error: nil, hideDetails: false)
        #expect(open == DownloadNotice(state: .completed, mediaTitle: "Clip", error: nil, hideDetails: false))
        #expect(open.title == "Download finished" && open.body == "Clip")
        let locked = DownloadNotice(state: .completed, mediaTitle: "Clip", error: nil, hideDetails: true)
        #expect(!locked.body.contains("Clip"))
        let failed = DownloadNotice(
            state: .failed, mediaTitle: "Clip", error: "Denied https://x.com", hideDetails: true)
        #expect(failed.title == "Download failed" && !failed.body.contains("x.com"))
    }
}
