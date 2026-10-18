import CryptoKit
import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowModels

@Suite("ModelStore")
struct ModelStoreTests {
    // Two tiny "models" standing in for turbo/small; payload bytes are deterministic.
    static func payload(_ seed: UInt8, count: Int) -> Data { Data((0..<count).map { UInt8(($0 &+ Int(seed)) % 256) }) }
    static let bigPayload = payload(1, count: 300_000)
    static let smallPayload = payload(2, count: 100_000)

    static func descriptor(id: String, payload: Data, isDefault: Bool) -> ModelDescriptor {
        ModelDescriptor(id: id, displayName: id, role: .speech,
                        downloadURL: URL(string: "https://example.com/\(id).bin")!,
                        sizeInBytes: Int64(payload.count),
                        sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                        languagesSummary: "test", isDefault: isDefault)
    }
    static let big = descriptor(id: "big", payload: bigPayload, isDefault: true)
    static let small = descriptor(id: "small", payload: smallPayload, isDefault: false)

    struct Harness {
        let dir = TemporaryDirectory()
        let downloader = FakeModelDownloader()
        let settings = InMemoryKeyValueStore()
        var freeSpace = FakeFreeSpace(available: 10_000_000_000)
        func store() -> ModelStore {
            ModelStore(directory: dir.url, catalog: [ModelStoreTests.big, ModelStoreTests.small],
                       downloader: downloader, freeSpace: freeSpace, settings: settings)
        }
        func serveAll() async {
            await downloader.serve(ModelStoreTests.bigPayload, at: ModelStoreTests.big.downloadURL)
            await downloader.serve(ModelStoreTests.smallPayload, at: ModelStoreTests.small.downloadURL)
        }
    }

    static func drain(_ stream: AsyncThrowingStream<ModelState, Error>) async throws -> [ModelState] {
        var states: [ModelState] = []
        for try await state in stream { states.append(state) }
        // A cancelled consuming task can end AsyncThrowingStream iteration with no error at all — the
        // stream's own cancellation-awareness resolves `next()` with nil before the producer's later
        // `continuation.finish(throwing:)` can land. Surface that as a thrown CancellationError so
        // callers (like cancelKeepsPartial) see it the way `install`'s own semantics intend.
        if Task.isCancelled { throw CancellationError() }
        return states
    }

    @Test("fresh directory: nothing installed, catalog default is not usable yet")
    func freshDirectory() async {
        let h = Harness()
        let store = h.store()
        #expect(await store.state(of: "big") == .notInstalled)
        #expect(await store.installedModels(role: .speech).isEmpty)
        #expect(await store.defaultModel(role: .speech) == nil)
    }

    @Test("install downloads, verifies and marks installed; default follows the catalog")
    func install() async throws {
        let h = Harness()
        await h.serveAll()
        let store = h.store()
        let states = try await Self.drain(await store.install(id: "big"))
        #expect(states.first == .downloading(bytesWritten: 65_536, total: 300_000))
        #expect(states.contains(.verifying))
        #expect(states.last == .installed)
        #expect(await store.state(of: "big") == .installed)
        #expect(await store.defaultModel(role: .speech)?.id == "big")
        #expect(FileManager.default.fileExists(atPath: h.dir.file("big.bin").path))
        #expect(!FileManager.default.fileExists(atPath: h.dir.file("big.bin.partial").path))
    }

    @Test("refuses to start when free space is below size + 500 MB reserve (SYS-DISK)")
    func insufficientSpace() async throws {
        var h = Harness()
        await h.serveAll()
        h.freeSpace = FakeFreeSpace(available: 300_000 + ModelStore.reserveBytes - 1)
        let store = h.store()
        await #expect(throws: ModelStoreError.insufficientDiskSpace(required: 300_000 + ModelStore.reserveBytes,
                                                                  available: 300_000 + ModelStore.reserveBytes - 1)) {
            _ = try await Self.drain(await store.install(id: "big"))
        }
        #expect(await h.downloader.calls.isEmpty)
    }

    @Test("going offline leaves a partial file; the next install resumes from it (ONB-04a)")
    func resume() async throws {
        let h = Harness()
        await h.serveAll()
        await h.downloader.setFailAfterBytes(131_072)
        let store = h.store()
        await #expect(throws: ModelStoreError.downloadInterrupted(bytesWritten: 131_072)) {
            _ = try await Self.drain(await store.install(id: "big"))
        }
        #expect(await store.state(of: "big") == .paused(bytesWritten: 131_072, total: 300_000))
        let states = try await Self.drain(await store.install(id: "big"))
        #expect(states.last == .installed)
        let calls = await h.downloader.calls
        #expect(calls.map(\.resumedFrom) == [0, 131_072])
    }

    @Test("discardDownload removes a partial left by an offline interruption (ST-03o Cancel download)")
    func discardDownloadRemovesPartial() async throws {
        let h = Harness()
        await h.serveAll()
        await h.downloader.setFailAfterBytes(131_072)
        let store = h.store()
        await #expect(throws: ModelStoreError.downloadInterrupted(bytesWritten: 131_072)) {
            _ = try await Self.drain(await store.install(id: "big"))
        }
        #expect(await store.state(of: "big") == .paused(bytesWritten: 131_072, total: 300_000))

        try await store.discardDownload(id: "big")

        #expect(await store.state(of: "big") == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: h.dir.file("big.bin.partial").path))
    }

    @Test("checksum mismatch deletes the file and reports failure (ST-03v)")
    func checksumMismatch() async throws {
        let h = Harness()
        await h.downloader.serve(Self.smallPayload, at: Self.big.downloadURL)   // wrong bytes for "big"
        let store = h.store()
        await #expect(throws: ModelStoreError.checksumMismatch) {
            _ = try await Self.drain(await store.install(id: "big"))
        }
        #expect(await store.state(of: "big") == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: h.dir.file("big.bin").path))
        #expect(!FileManager.default.fileExists(atPath: h.dir.file("big.bin.partial").path))
    }

    @Test("the only installed speech model cannot be removed (ST-03d)")
    func cannotRemoveOnly() async throws {
        let h = Harness()
        await h.serveAll()
        let store = h.store()
        _ = try await Self.drain(await store.install(id: "big"))
        await #expect(throws: ModelStoreError.cannotRemoveOnlyModel("big")) { try await store.remove(id: "big") }
    }

    @Test("removing the default switches the default to another installed model")
    func removeSwitchesDefault() async throws {
        let h = Harness()
        await h.serveAll()
        let store = h.store()
        _ = try await Self.drain(await store.install(id: "big"))
        _ = try await Self.drain(await store.install(id: "small"))
        #expect(await store.defaultModel(role: .speech)?.id == "big")
        try await store.remove(id: "big")
        #expect(await store.state(of: "big") == .notInstalled)
        #expect(await store.defaultModel(role: .speech)?.id == "small")
        #expect(h.settings.string(forKey: "models.default.speech") == "small")
    }

    @Test("a file deleted behind the store's back reads as not installed, with no re-download")
    func manualDeletion() async throws {
        let h = Harness()
        await h.serveAll()
        let store = h.store()
        _ = try await Self.drain(await store.install(id: "big"))
        try FileManager.default.removeItem(at: h.dir.file("big.bin"))
        #expect(await store.state(of: "big") == .notInstalled)
        #expect(await store.installedModels(role: .speech).isEmpty)
        #expect(await h.downloader.calls.count == 1)
    }

    @Test("a second install of the same model while one is running is rejected, not doubled")
    func concurrentInstallIsRejected() async throws {
        let h = Harness()
        await h.serveAll()
        let store = h.store()
        async let first = Self.drain(await store.install(id: "big"))
        async let second = Self.drain(await store.install(id: "big"))
        var outcomes: [Result<[ModelState], Error>] = []
        do { outcomes.append(.success(try await first)) } catch { outcomes.append(.failure(error)) }
        do { outcomes.append(.success(try await second)) } catch { outcomes.append(.failure(error)) }
        let successes = outcomes.compactMap { try? $0.get() }
        let failures = outcomes.compactMap { if case .failure(let e) = $0 { e as? ModelStoreError } else { nil } }
        // Two legal interleavings under the actor's atomic `inProgress` guard:
        // (a) the two `install` calls truly overlap: the second observes `inProgress[id] != nil`
        //     and throws `.alreadyInProgress` while the first proceeds to download and install
        //     (one success, one failure); or
        // (b) the actor happens to fully serialize them (the first finishes installing before the
        //     second's `performInstall` body starts): the second then sees `.installed` at its own
        //     top-of-body check and returns success without downloading again (two successes, no
        //     failure). Either way exactly one download happens and the model ends up installed.
        #expect(successes.count + failures.count == 2)
        #expect((1...2).contains(successes.count))
        #expect(successes.allSatisfy { $0.last == .installed })
        #expect(failures.isEmpty || failures == [.alreadyInProgress("big")])
        #expect(await h.downloader.calls.count == 1)      // never downloaded twice, in either interleaving
        #expect(await store.state(of: "big") == .installed)
    }

    @Test("setDefault persists and rejects models that are not installed")
    func setDefault() async throws {
        let h = Harness()
        await h.serveAll()
        let store = h.store()
        await #expect(throws: ModelStoreError.notInstalled("small")) { try await store.setDefault(id: "small") }
        _ = try await Self.drain(await store.install(id: "small"))
        try await store.setDefault(id: "small")
        #expect(h.settings.string(forKey: "models.default.speech") == "small")
    }

    @Test("an oversized partial is discarded and the download restarts from zero")
    func oversizedPartialRestarts() async throws {
        let h = Harness()
        await h.serveAll()
        try Data(repeating: 7, count: 300_001).write(to: h.dir.file("big.bin.partial"))
        let store = h.store()
        #expect(await store.state(of: "big") == .notInstalled)
        let states = try await Self.drain(await store.install(id: "big"))
        #expect(states.last == .installed)
        #expect(await h.downloader.calls.map(\.resumedFrom) == [0])
    }

    @Test("cancelInstall waits for the producer's cleanup: state is paused right after it returns")
    func cancelInstallWaitsForCleanup() async throws {
        let h = Harness()
        await h.serveAll()
        await h.downloader.setBlockAfterBytes(131_072)
        let store = h.store()
        let consumer = Task { try await Self.drain(await store.install(id: "big")) }
        await h.downloader.waitUntilBlocked()
        await store.cancelInstall(id: "big")
        #expect(await store.state(of: "big") == .paused(bytesWritten: 131_072, total: 300_000))   // no yielding needed
        await #expect(throws: CancellationError.self) { try await consumer.value }
        await store.cancelInstall(id: "big")   // idempotent when nothing is in flight
        #expect(await store.state(of: "big") == .paused(bytesWritten: 131_072, total: 300_000))
    }

    @Test("cancelling an install keeps the partial and reports paused (ST-03o pause)")
    func cancelKeepsPartial() async throws {
        let h = Harness()
        await h.serveAll()
        await h.downloader.setBlockAfterBytes(131_072)        // park after two 64 KiB chunks
        let store = h.store()
        let task = Task { try await Self.drain(await store.install(id: "big")) }
        await h.downloader.waitUntilBlocked()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        // The producer's cleanup (`defer { inProgress[id] = nil }`) runs on its own task; yield until it has.
        var state = await store.state(of: "big")
        for _ in 0..<1_000 where state != .paused(bytesWritten: 131_072, total: 300_000) {
            await Task.yield()
            state = await store.state(of: "big")
        }
        #expect(state == .paused(bytesWritten: 131_072, total: 300_000))
        #expect(try FileManager.default.attributesOfItem(atPath: h.dir.file("big.bin.partial").path)[.size] as? Int64 == 131_072)
    }

    @Test("a catalog entry without a checksum cannot be installed (ST-03v)")
    func checksumUnknown() async throws {
        let h = Harness()
        let unpinned = Self.descriptor(id: "unpinned", payload: Self.smallPayload, isDefault: false)
        let withoutChecksum = ModelDescriptor(id: unpinned.id, displayName: unpinned.displayName, role: unpinned.role,
                                              downloadURL: unpinned.downloadURL, sizeInBytes: unpinned.sizeInBytes,
                                              sha256: "", languagesSummary: unpinned.languagesSummary, isDefault: unpinned.isDefault)
        let store = ModelStore(directory: h.dir.url, catalog: [withoutChecksum], downloader: h.downloader,
                               freeSpace: h.freeSpace, settings: h.settings)
        await #expect(throws: ModelStoreError.checksumUnknown("unpinned")) {
            _ = try await Self.drain(await store.install(id: "unpinned"))
        }
        #expect(await h.downloader.calls.isEmpty)
    }
}
