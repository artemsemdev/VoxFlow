import CryptoKit
import Foundation
import Testing
import VoxFlowCore
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

/// Settings › Models (design ST-03, ST-03v, ST-03d, ST-03o, SYS-DISK). Two speech models — `big`
/// (300 000 B, catalog default) / `small` (100 000 B) — plus one style row with an empty checksum,
/// matching the real Qwen catalog entry that ships in phase 5 (`Row.isAvailable == false`).
@Suite("ModelsViewModel") @MainActor
struct ModelsViewModelTests {
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
        func viewModel() -> ModelsViewModel { ModelsViewModel(store: store(), catalog: ModelsViewModelTests.catalog) }
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
        #expect(ModelsViewModel.gigabytes(487_601_967) == "488 MB")
        #expect(ModelsViewModel.gigabytes(744_000_000) == "744 MB")
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

    @Test("a checksum mismatch reports downloadFailed and leaves the row not installed")
    func checksumMismatch() async throws {
        let h = Harness()
        await h.downloader.serve(Self.smallPayload, at: Self.big.downloadURL)   // wrong bytes for "big"
        let model = h.viewModel()

        await model.download(Self.big)

        #expect(model.alert == .downloadFailed(Self.big, reason: "The download didn't verify (checksum mismatch). Nothing was installed and the file was deleted."))
        #expect(model.speechRows.first { $0.id == "big" }?.state == .notInstalled)
    }

    // MARK: 5. offlineThenResume

    @Test("going offline mid-download surfaces .offline and resume continues from the partial")
    func offlineThenResume() async throws {
        let h = Harness()
        await h.serveAll()
        await h.downloader.setFailAfterBytes(131_072)
        let model = h.viewModel()

        await model.download(Self.big)
        #expect(model.alert == .offline(Self.big, bytesWritten: 131_072, total: 300_000))
        #expect(model.speechRows.first { $0.id == "big" }?.state == .paused(bytesWritten: 131_072, total: 300_000))

        await model.resume(Self.big)
        #expect(model.alert == nil)
        #expect(model.speechRows.first { $0.id == "big" }?.state == .installed)
        let calls = await h.downloader.calls
        #expect(calls.map(\.resumedFrom) == [0, 131_072])
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
        model.pause(Self.big)
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
        #expect(model.alert == .removeModel(Self.big))

        await model.confirmRemove()
        #expect(model.alert == nil)
        #expect(model.speechRows.first { $0.id == "big" }?.state == .notInstalled)
        #expect(model.speechRows.first { $0.id == "small" }?.isDefault == true)
    }

    // MARK: Alert copy (controller ruling 5)

    @Test("SYS-DISK alert copy uses gigabytes for both numbers")
    func insufficientSpaceCopy() {
        #expect(ModelsViewModel.insufficientSpaceTitle == "Not enough free space")
        let message = ModelsViewModel.insufficientSpaceMessage(Self.big, available: 900_000_000)
        #expect(message == "big needs \(ModelsViewModel.gigabytes(Self.big.sizeInBytes)) plus 500 MB to unpack. This Mac has 900 MB free.")
    }

    @Test("Remove-model alert copy names the model and frees its size")
    func removeCopy() {
        #expect(ModelsViewModel.removeTitle(Self.small) == "Remove small?")
        #expect(ModelsViewModel.removeMessage(Self.small) == "Frees \(ModelsViewModel.gigabytes(Self.small.sizeInBytes)). You can download it again anytime.")
    }
}
