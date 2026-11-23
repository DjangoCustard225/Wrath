import Foundation
import Testing

@testable import WrathCore

@Suite struct AppSheetPresentationTests {
    @Test func waitsForTheOutgoingSheetBeforePresentingTheNext() {
        var presentation = AppSheetPresentation()
        presentation.present(.addLink)
        #expect(presentation.sheet == .addLink)
        presentation.present(.redditLogin)
        #expect(presentation.sheet == nil)
        #expect(presentation.isDismissing)
        presentation.didDismiss()
        #expect(presentation.sheet == .redditLogin)
        #expect(!presentation.isDismissing)
    }

    @Test func followsTheActiveDownload() {
        let id = UUID()
        var presentation = AppSheetPresentation()
        presentation.downloadChanged(id)
        #expect(presentation.sheet == .download(id))
        presentation.downloadChanged(nil)
        #expect(presentation.sheet == nil)
        presentation.didDismiss()
        #expect(presentation.sheet == nil)
    }
}

@Suite struct TransferPresentationMeterTests {
    @Test func reportsSpeedAndETAAfterEnoughSamples() throws {
        var meter = TransferPresentationMeter()
        let start = meter.sample(bytes: 0, total: 1_000, time: 0)
        #expect(start.speed == 0)
        #expect(start.eta == nil)
        let later = meter.sample(bytes: 400, total: 1_000, time: 2)
        #expect(later.speed == 200)
        #expect(try #require(later.eta) == 3)
        #expect(later.fraction == 0.4)
    }

    @Test func restartsWhenBytesGoBackwards() {
        var meter = TransferPresentationMeter()
        _ = meter.sample(bytes: 500, total: nil, time: 0)
        let reset = meter.sample(bytes: 100, total: nil, time: 3)
        #expect(reset.speed == 0)
        #expect(reset.fraction == nil)
    }
}

@Suite struct BackgroundDownloadProgressTests {
    @Test func mapsStatesToSystemProgress() {
        let resolving = BackgroundDownloadProgress(
            title: "Clip", state: .resolving, fraction: 0, known: false, phase: .preparing, paused: false,
            receivedBytes: 0)
        #expect(resolving.total == -1)
        #expect(resolving.subtitle == "Finding media")

        let downloading = BackgroundDownloadProgress(
            title: "Clip", state: .downloading, fraction: 0.5, known: true, phase: .preparing, paused: false,
            receivedBytes: 10)
        #expect(downloading.total == 1_000)
        #expect(downloading.completed == 450)

        let hidden = BackgroundDownloadProgress(
            title: "Private", state: .completed, fraction: 1, known: true, phase: .saving, paused: false,
            receivedBytes: 0, hideDetails: true)
        #expect(hidden.title == "Wrath download")
        #expect(hidden.completed == hidden.total)
    }

    @Test func heartbeatNeverFinishesTheTask() {
        var completed: Int64 = 900
        for _ in 0..<2_000 { completed = BackgroundDownloadProgress.heartbeat(completed: completed, total: 1_000) }
        #expect(completed == 999)
        #expect(BackgroundDownloadProgress.heartbeat(completed: 900, total: 1_000) == 902)
        #expect(BackgroundDownloadProgress.heartbeat(completed: 5, total: -1) == 6)
    }
}

@Suite struct BackgroundTaskIdentityTests {
    private let renamed = "app.wrath.downloader.ABC123"
    private let shipped = ["app.wrath.downloader.download.*"]

    @Test func prefixFollowsTheRunningBundle() {
        #expect(BackgroundTaskIdentity.prefix(bundleIdentifier: renamed) == renamed + ".download.")
        #expect(BackgroundTaskIdentity.prefix(bundleIdentifier: nil) == "app.wrath.downloader.download.")
    }

    @Test func checksPermittedIdentifiersLikeTheScheduler() {
        #expect(BackgroundTaskIdentity.isPermitted("app.wrath.downloader.download.x", by: shipped))
        #expect(!BackgroundTaskIdentity.isPermitted(renamed + ".download.x", by: shipped))
        #expect(BackgroundTaskIdentity.isPermitted("exact", by: ["exact"]))
    }

    @Test func patchedInfoPermitsTheRenamedBundle() throws {
        let info: [String: Any] = ["CFBundleIdentifier": renamed, BackgroundTaskIdentity.infoKey: shipped]
        let patched = BackgroundTaskIdentity.patchedInfo(info, runningIdentifier: renamed)
        #expect(patched["CFBundleIdentifier"] as? String == BackgroundTaskIdentity.originalBundleIdentifier)
        let permitted = try #require(patched[BackgroundTaskIdentity.infoKey] as? [String])
        #expect(BackgroundTaskIdentity.isPermitted(renamed + ".download.x", by: permitted))
        #expect(BackgroundTaskIdentity.isPermitted("app.wrath.downloader.download.x", by: permitted))

        let ext = BackgroundTaskIdentity.patchedExtensionInfo(
            ["CFBundleIdentifier": renamed + ".Share"], runningIdentifier: renamed)
        #expect(ext["CFBundleIdentifier"] as? String == "app.wrath.downloader.Share")
    }
}
