import CryptoKit
import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

/// Settings › Models (design ST-03, ST-03v, ST-03d, ST-03o, SYS-DISK). Two speech models — `big`
/// (300 000 B, catalog default) / `small` (100 000 B) — plus one style row with an empty checksum,
/// matching the real Qwen catalog entry that ships in phase 5 (`Row.isAvailable == false`).
/// Records whether/how often `openStorageSettings()` (SYS-DISK "Free up space…") was called,
/// without actually opening System Settings during tests.
final class FakeSystemSettingsOpener: SystemSettingsOpening, @unchecked Sendable {
    private(set) var openStorageSettingsCallCount = 0
    func openStorageSettings() { openStorageSettingsCallCount += 1 }
}

/// Deterministic clock for `ModelsViewModel`'s injected `now:` (design 3d / F): returns each date
/// in `times` in order, then freezes on the last one — lets a test drive `ETAEstimator` samples at
/// exact, arbitrary intervals without depending on wall-clock timing.
final class SequentialClock: Sendable {
    private let state: Mutex<(times: [Date], index: Int)>
    init(_ times: [Date]) { state = Mutex((times: times, index: 0)) }
    func now() -> Date {
        state.withLock { box in
            let date = box.index < box.times.count ? box.times[box.index] : (box.times.last ?? Date())
            box.index += 1
            return date
        }
    }
}

@Suite("ModelsViewModel") @MainActor
struct ModelsViewModelTests {
    @Test("loading row exposes the ST-03v first-use copy")
    func loadingRowCopy() {
        let row = ModelsViewModel.Row(model: Self.big, state: .installed, isDefault: true, isLoadingIntoMemory: true)
        #expect(row.statusSubtitle == "Loading into memory…")
        #expect(row.statusContext == "first use")
    }

    static func payload(_ seed: UInt8, count: Int) -> Data { Data((0..<count).map { UInt8(($0 &+ Int(seed)) % 256) }) }
    static let bigPayload = payload(1, count: 300_000)
    static let smallPayload = payload(2, count: 100_000)

    static func descriptor(id: String, role: ModelRole, payload: Data, isDefault: Bool) -> ModelDescriptor {
        ModelDescriptor(id: id, displayName: id, role: role,
                        downloadURL: URL(string: "https://example.com/\(id).bin")!,
                        sizeInBytes: Int64(payload.count),
                        sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                        languagesSummary: "test", isDefault: isDefault)
    }
    static let big = descriptor(id: "big", role: .speech, payload: bigPayload, isDefault: true)
    static let small = descriptor(id: "small", role: .speech, payload: smallPayload, isDefault: false)
    static let style = ModelDescriptor(id: "style", displayName: "style", role: .style,
                                       downloadURL: URL(string: "https://example.com/style.bin")!,
                                       sizeInBytes: 200_000, sha256: "", languagesSummary: "style test", isDefault: true)
    static let catalog = [big, small, style]

    @MainActor
    struct Harness {
        let dir = TemporaryDirectory()
        let downloader = FakeModelDownloader()
        let settings = InMemoryKeyValueStore()
        var freeSpace = FakeFreeSpace(available: 10_000_000_000)
        func store() -> ModelStore {
            ModelStore(directory: dir.url, catalog: ModelsViewModelTests.catalog,
                       downloader: downloader, freeSpace: freeSpace, settings: settings)
        }
        func viewModel(settingsOpener: any SystemSettingsOpening = FakeSystemSettingsOpener(),
                       now: @escaping () -> Date = { Date() }) -> ModelsViewModel {
            ModelsViewModel(store: store(), catalog: ModelsViewModelTests.catalog, settingsOpener: settingsOpener, now: now)
        }
        func serveAll() async {
            await downloader.serve(ModelsViewModelTests.bigPayload, at: ModelsViewModelTests.big.downloadURL)
            await downloader.serve(ModelsViewModelTests.smallPayload, at: ModelsViewModelTests.small.downloadURL)
        }
    }

    static func drain(_ stream: AsyncThrowingStream<ModelState, Error>) async throws -> [ModelState] {
        var states: [ModelState] = []
        for try await state in stream { states.append(state) }
        if Task.isCancelled { throw CancellationError() }
        return states
    }

    // MARK: gigabytes (controller ruling 2)

    @Test("gigabytes formats decimal GB/MB per the design examples")
    func gigabytes() {
        #expect(ModelsViewModel.gigabytes(1_624_555_275) == "1.6 GB")
        #expect(ModelsViewModel.gigabytes(487_601_967) == "480 MB")
        #expect(ModelsViewModel.gigabytes(744_000_000) == "740 MB")
    }

    // MARK: 1. refreshReflectsDisk

    @Test("refresh mirrors disk state and the footer text")
    func refreshReflectsDisk() async throws {
        let h = Harness()
        let store = h.store()
        let model = ModelsViewModel(store: store, catalog: Self.catalog)
        await model.refresh()

        #expect(model.speechRows.map(\.state) == [.notInstalled, .notInstalled])
        #expect(model.styleRows.count == 1)
        #expect(model.styleRows[0].isAvailable == false)

        await h.serveAll()
        _ = try await Self.drain(await store.install(id: "big"))
        await model.refresh()

        let bigRow = try #require(model.speechRows.first { $0.id == "big" })
        #expect(bigRow.state == .installed)
        #expect(bigRow.isDefault)
        #expect(model.footerText.hasSuffix("never checks for or fetches anything on its own."))
        #expect(model.footerText.contains(ModelsViewModel.abbreviate(await store.directory)))
    }

    // MARK: 2. downloadStates

    @Test("download observes .downloading then ends .installed, with no alert")
    func downloadStates() async throws {
        let h = Harness()
        await h.serveAll()
        await h.downloader.setBlockAfterBytes(65_536)   // park after the first chunk
        let model = h.viewModel()
        await model.refresh()   // seed the rows so the loop's setState(...) below has something to update

        let task = Task { await model.download(Self.big) }
        await h.downloader.waitUntilBlocked()
        // `waitUntilBlocked()` only guarantees the *producer* (the downloader's own actor task) has
        // reached the park point — the row update happens on a separate consumer task (this view
        // model's `download()` loop) that may not have run yet. Poll (yield, no sleep) for it to
        // catch up, same technique `ModelStoreTests.cancelKeepsPartial` uses for the store's state.
        var midState = model.speechRows.first { $0.id == "big" }?.state
        for _ in 0..<1_000 where midState != .downloading(bytesWritten: 65_536, total: 300_000) {
            await Task.yield()
            midState = model.speechRows.first { $0.id == "big" }?.state
        }
        #expect(midState == .downloading(bytesWritten: 65_536, total: 300_000))

        await h.downloader.release()
        await task.value

        // `.verifying` itself isn't independently gated (FakeModelDownloader has no hook for the
        // post-download checksum phase, and ModelStoreTests already covers that transition); this
        // asserts the download ran the whole way through to a verified install.
        #expect(model.alert == nil)
        #expect(model.speechRows.first { $0.id == "big" }?.state == .installed)
        #expect(await h.downloader.calls.count == 1)
    }

    // MARK: refreshDoesNotClobberActiveDownload (fix round 1, item 1)

    @Test("refresh() while a download is active keeps the live row state instead of a stale store read")
    func refreshDoesNotClobberActiveDownload() async throws {
        let h = Harness()
        await h.serveAll()
        await h.downloader.setBlockAfterBytes(131_072)
        let model = h.viewModel()
        await model.refresh()

        let task = Task { await model.download(Self.big) }
        await h.downloader.waitUntilBlocked()
        var midState = model.speechRows.first { $0.id == "big" }?.state
        for _ in 0..<1_000 where midState != .downloading(bytesWritten: 131_072, total: 300_000) {
            await Task.yield()
            midState = model.speechRows.first { $0.id == "big" }?.state
        }
        #expect(midState == .downloading(bytesWritten: 131_072, total: 300_000))

        // A refresh triggered while the download is still in flight (e.g. the view's 1 Hz poll)
        // must not roll the row back to whatever the store's own on-disk read happens to say —
        // the stream (already reflected in `midState` above) stays authoritative for this row.
        await model.refresh()
        #expect(model.speechRows.first { $0.id == "big" }?.state == .downloading(bytesWritten: 131_072, total: 300_000))

        await h.downloader.release()
        await task.value
        #expect(model.speechRows.first { $0.id == "big" }?.state == .installed)
    }

    // MARK: 3. insufficientSpace

    @Test("insufficient space surfaces the SYS-DISK alert; useSmallerModelInstead falls back to the smaller model")
    func insufficientSpace() async throws {
        var h = Harness()
        await h.serveAll()
        h.freeSpace = FakeFreeSpace(available: 300_000 + ModelStore.reserveBytes - 1)
        let model = h.viewModel()

        await model.download(Self.big)
        #expect(model.alert == .insufficientSpace(Self.big, required: 300_000 + ModelStore.reserveBytes,
                                                   available: 300_000 + ModelStore.reserveBytes - 1))

        await model.useSmallerModelInstead()
        #expect(model.alert == nil)
        let calls = await h.downloader.calls
        #expect(calls.map(\.url) == [Self.small.downloadURL])
        #expect(model.speechRows.first { $0.id == "small" }?.state == .installed)
    }

    // MARK: 4. checksumMismatch

    @Test("a checksum mismatch stays inline and Retry installs the replacement download")
    func checksumMismatch() async throws {
        let h = Harness()
        await h.downloader.serve(Self.smallPayload, at: Self.big.downloadURL)   // wrong bytes for "big"
        let model = h.viewModel()

        await model.download(Self.big)

        #expect(model.alert == nil)
        #expect(model.speechRows.first { $0.id == "big" }?.failureReason
                == ModelsViewModel.checksumFailureMessage)

        await h.downloader.serve(Self.bigPayload, at: Self.big.downloadURL)
        await model.retry(Self.big)

        #expect(model.speechRows.first { $0.id == "big" }?.state == .installed)
        #expect(model.speechRows.first { $0.id == "big" }?.failureReason == nil)
    }

    // MARK: 5. offlineThenResume

    @Test("going offline mid-download surfaces .offline and resume continues from the partial")
    func offlineThenResume() async throws {
        let h = Harness()
        await h.serveAll()
        await h.downloader.setFailAfterBytes(131_072)
        let model = h.viewModel()

        await model.download(Self.big)
        // No speech model is installed yet at this point, so dictation has nothing to fall back to.
        #expect(model.alert == .offline(Self.big, bytesWritten: 131_072, total: 300_000, dictationKeepsWorking: false))
        #expect(model.speechRows.first { $0.id == "big" }?.state == .paused(bytesWritten: 131_072, total: 300_000))

        await model.resume(Self.big)
        #expect(model.alert == nil)
        #expect(model.speechRows.first { $0.id == "big" }?.state == .installed)
        let calls = await h.downloader.calls
        #expect(calls.map(\.resumedFrom) == [0, 131_072])
    }

    @Test("offline dictationKeepsWorking is true once another speech model is already installed")
    func offlineWithFallbackModel() async throws {
        let h = Harness()
        await h.serveAll()
        let model = h.viewModel()
        await model.download(Self.small)   // small installs first, so it's the fallback

        await h.downloader.setFailAfterBytes(131_072)
        await model.download(Self.big)
        #expect(model.alert == .offline(Self.big, bytesWritten: 131_072, total: 300_000, dictationKeepsWorking: true))
    }

    // MARK: discardDownload (fix round 1, item 3b)

    @Test("discardDownload (ST-03o Cancel download) deletes the partial and never touches the downloader")
    func discardDownloadResetsToNotInstalled() async throws {
        let h = Harness()
        await h.serveAll()
        await h.downloader.setFailAfterBytes(131_072)
        let model = h.viewModel()

        await model.download(Self.big)
        #expect(model.speechRows.first { $0.id == "big" }?.state == .paused(bytesWritten: 131_072, total: 300_000))
        let callsBeforeDiscard = await h.downloader.calls.count

        await model.discardDownload(Self.big)

        #expect(model.alert == nil)
        #expect(model.speechRows.first { $0.id == "big" }?.state == .notInstalled)
        #expect(await h.downloader.calls.count == callsBeforeDiscard)   // discarding never calls the downloader
    }

    // MARK: downloadText ETA (F)

    @Test("downloadText adds an ETA once two downloading samples 10 s apart give ETAEstimator a rate")
    func downloadTextShowsETA() async throws {
        let h = Harness()
        await h.serveAll()
        // One chunk per block point (15 000 B each) means exactly the two downloading states this
        // test cares about are ever emitted — no intermediate samples to reason about.
        await h.downloader.setChunkSize(15_000)
        await h.downloader.setBlockAfterBytes(15_000)
        let clock = SequentialClock([Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 10)])
        let model = h.viewModel(now: clock.now)
        await model.refresh()   // seed the rows so setState(...) below has something to update

        let task = Task { await model.download(Self.big) }
        await h.downloader.waitUntilBlocked()
        var firstState = model.speechRows.first { $0.id == "big" }?.state
        for _ in 0..<1_000 where firstState != .downloading(bytesWritten: 15_000, total: 300_000) {
            await Task.yield()
            firstState = model.speechRows.first { $0.id == "big" }?.state
        }
        #expect(firstState == .downloading(bytesWritten: 15_000, total: 300_000))
        let firstRow = try #require(model.speechRows.first { $0.id == "big" })
        // One sample isn't enough for ETAEstimator to have a rate yet — no " · … left" suffix.
        #expect(model.downloadText(for: firstRow) == ModelsViewModel.progressText(written: 15_000, total: 300_000))

        await h.downloader.setBlockAfterBytes(30_000)
        await h.downloader.release()
        await h.downloader.waitUntilBlocked()
        var secondState = model.speechRows.first { $0.id == "big" }?.state
        for _ in 0..<1_000 where secondState != .downloading(bytesWritten: 30_000, total: 300_000) {
            await Task.yield()
            secondState = model.speechRows.first { $0.id == "big" }?.state
        }
        #expect(secondState == .downloading(bytesWritten: 30_000, total: 300_000))
        // progress 0.05 at t=0, 0.10 at t=10 → rate 0.005/s → (1 - 0.10) / 0.005 = 180 s = "3 min left".
        let secondRow = try #require(model.speechRows.first { $0.id == "big" })
        #expect(model.downloadText(for: secondRow) == "\(ModelsViewModel.progressText(written: 30_000, total: 300_000)) · 3 min left")

        await h.downloader.release()
        await task.value
    }

    // MARK: discardDownload while still running (T4)

    @Test("discardDownload surfaces alreadyInProgress as its own alert instead of silently no-op'ing")
    func discardDownloadWhileInProgressSurfacesAlert() async throws {
        let h = Harness()
        await h.serveAll()
        await h.downloader.setBlockAfterBytes(131_072)
        let model = h.viewModel()

        let task = Task { await model.download(Self.big) }
        await h.downloader.waitUntilBlocked()   // download() is still running: the store's inProgress[id] is set

        await model.discardDownload(Self.big)

        #expect(model.alert == .downloadFailed(Self.big, reason: "The download is still running; pause it first."))

        await h.downloader.release()
        await task.value
    }

    // MARK: openStorageSettings (fix round 1, item 3a)

    @Test("openStorageSettings() delegates to the injected SystemSettingsOpening")
    func openStorageSettingsDelegates() async throws {
        let h = Harness()
        let opener = FakeSystemSettingsOpener()
        let model = h.viewModel(settingsOpener: opener)

        model.openStorageSettings()

        #expect(opener.openStorageSettingsCallCount == 1)
    }

    // MARK: 6. pauseKeepsPartial

    @Test("pause cancels the install task and keeps the partial (ST-03o pause)")
    func pauseKeepsPartial() async throws {
        let h = Harness()
        await h.serveAll()
        await h.downloader.setBlockAfterBytes(131_072)
        let model = h.viewModel()

        let task = Task { await model.download(Self.big) }
        await h.downloader.waitUntilBlocked()
        await model.pause(Self.big)
        await task.value

        #expect(model.alert == nil)
        #expect(model.speechRows.first { $0.id == "big" }?.state == .paused(bytesWritten: 131_072, total: 300_000))
    }

    // MARK: 7. removeRules

    @Test("requestRemove blocks the only installed speech model; confirmRemove switches the default")
    func removeRules() async throws {
        let h = Harness()
        await h.serveAll()
        let store = h.store()
        _ = try await Self.drain(await store.install(id: "big"))
        let model = ModelsViewModel(store: store, catalog: Self.catalog)
        await model.refresh()

        await model.requestRemove(Self.big)
        #expect(model.alert == .cannotRemoveOnlyModel(Self.big))

        _ = try await Self.drain(await store.install(id: "small"))
        await model.refresh()

        await model.requestRemove(Self.big)
        #expect(model.alert == .removeModel(Self.big, keeps: "small"))

        await model.confirmRemove()
        #expect(model.alert == nil)
        #expect(model.speechRows.first { $0.id == "big" }?.state == .notInstalled)
        #expect(model.speechRows.first { $0.id == "small" }?.isDefault == true)
    }

    // MARK: 8. styleModelIsDownloadable (phase 5, Task 3 — the pinned Qwen entry ships with a real
    // checksum now, so a `.style` row is downloadable like any speech row, not stuck `isAvailable == false`).

    @Test("a .style row with a real checksum downloads and installs like any other model")
    func styleModelIsDownloadable() async throws {
        let payload = Self.payload(9, count: 50_000)
        let styleModel = Self.descriptor(id: "style-real", role: .style, payload: payload, isDefault: true)
        let catalog = [Self.big, styleModel]
        let dir = TemporaryDirectory()
        let downloader = FakeModelDownloader()
        await downloader.serve(payload, at: styleModel.downloadURL)
        let store = ModelStore(directory: dir.url, catalog: catalog, downloader: downloader,
                               freeSpace: FakeFreeSpace(available: 10_000_000_000), settings: InMemoryKeyValueStore())
        let model = ModelsViewModel(store: store, catalog: catalog)
        await model.refresh()
        #expect(model.styleRows.first?.isAvailable == true)   // a real sha256 makes the row downloadable

        await model.download(styleModel)

        #expect(model.alert == nil)
        #expect(model.styleRows.first { $0.id == "style-real" }?.state == .installed)
    }

    // MARK: 9. removingOnlyStyleModelNeverBlocked

    @Test("removing the only installed style model is never blocked (unlike speech), and its alert carries no fallback-model clause")
    func removingOnlyStyleModelNeverBlocked() async throws {
        let payload = Self.payload(9, count: 50_000)
        let styleModel = Self.descriptor(id: "style-real", role: .style, payload: payload, isDefault: true)
        let catalog = [styleModel]
        let dir = TemporaryDirectory()
        let downloader = FakeModelDownloader()
        await downloader.serve(payload, at: styleModel.downloadURL)
        let store = ModelStore(directory: dir.url, catalog: catalog, downloader: downloader,
                               freeSpace: FakeFreeSpace(available: 10_000_000_000), settings: InMemoryKeyValueStore())
        let model = ModelsViewModel(store: store, catalog: catalog)
        await model.refresh()
        await model.download(styleModel)

        await model.requestRemove(styleModel)

        // `requestRemove` only blocks removal for `.speech` models with nothing else installed — a
        // style model always goes straight to `.removeModel`, even as the only one installed, and
        // `keeps: nil` (existing `removeMessage` behaviour) omits the "Dictation keeps using …" clause.
        #expect(model.alert == .removeModel(styleModel, keeps: nil))
        #expect(!ModelsViewModel.removeMessage(styleModel, keeps: nil).contains("Dictation keeps using"))

        await model.confirmRemove()
        #expect(model.alert == nil)
        #expect(model.styleRows.first { $0.id == "style-real" }?.state == .notInstalled)
    }

    // MARK: Alert copy (controller ruling 5)

    @Test("SYS-DISK alert copy uses gigabytes for both numbers")
    func insufficientSpaceCopy() {
        #expect(ModelsViewModel.insufficientSpaceTitle == "Not enough free space")
        let message = ModelsViewModel.insufficientSpaceMessage(Self.big, available: 900_000_000)
        #expect(message == "big needs \(ModelsViewModel.gigabytes(Self.big.sizeInBytes)) plus 500 MB to unpack. This Mac has 900 MB free.")
    }

    @Test("Remove-model alert copy names the model, frees its size, and names what stays default")
    func removeCopy() {
        #expect(ModelsViewModel.removeTitle(Self.small) == "Remove small?")
        #expect(ModelsViewModel.removeMessage(Self.small, keeps: "big")
                == "Frees \(ModelsViewModel.gigabytes(Self.small.sizeInBytes)). Dictation keeps using big. You can download it again anytime.")
        // No other model of the same role remains: the middle sentence is omitted entirely.
        #expect(ModelsViewModel.removeMessage(Self.small, keeps: nil)
                == "Frees \(ModelsViewModel.gigabytes(Self.small.sizeInBytes)). You can download it again anytime.")
    }

    @Test("cannotRemoveOnlyModel alert copy is exact")
    func cannotRemoveOnlyModelCopy() {
        #expect(ModelsViewModel.cannotRemoveOnlyModelTitle == "This is the only installed speech model")
        #expect(ModelsViewModel.cannotRemoveOnlyModelMessage == "Download another model before removing it.")
    }

    @Test("offline alert copy adds the dictation-keeps-working clause only when true")
    func offlineCopy() {
        #expect(ModelsViewModel.offlineTitle == "Download paused — you're offline")
        let base = ModelsViewModel.offlineMessage(bytesWritten: 131_072, total: 300_000, dictationKeepsWorking: false)
        #expect(base == "\(ModelsViewModel.gigabytes(131_072)) of \(ModelsViewModel.gigabytes(300_000)) saved. It will resume when you're back online.")
        let withFallback = ModelsViewModel.offlineMessage(bytesWritten: 131_072, total: 300_000, dictationKeepsWorking: true)
        #expect(withFallback == base + " Dictation keeps working with your installed model.")
    }
}
