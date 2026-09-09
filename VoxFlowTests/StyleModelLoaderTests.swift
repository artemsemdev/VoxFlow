import Foundation
import Testing
import VoxFlowCore
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

/// `StyleModelLoader` (plan ruling 4): lazy owner of the style model, ready only once the default
/// `.style` model from `ModelStore` is loaded into the engine.
@Suite("StyleModelLoader")
struct StyleModelLoaderTests {
    /// Real catalog's Qwen entry — used so `state(of:)`'s installed check and the loaded URL's file
    /// name both match production without a bespoke descriptor.
    private static let styleModel = ModelCatalog.all.first { $0.role == .style }!

    private func store(dir: TemporaryDirectory) -> ModelStore {
        ModelStore(directory: dir.url, downloader: FakeModelDownloader(), freeSpace: FakeFreeSpace(available: 10_000_000_000),
                   settings: InMemoryKeyValueStore())
    }

    /// `ModelStore.state(of:)` reports `.installed` only when the file on disk is exactly
    /// `sizeInBytes` — a sparse file of that exact size satisfies it without writing ~2 GB of data.
    private func installStyleModelFile(in dir: TemporaryDirectory) throws {
        let url = dir.url.appendingPathComponent(Self.styleModel.fileName)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(Self.styleModel.sizeInBytes))
        try handle.close()
    }

    @Test("no style model on disk: not ready, and the engine is never touched")
    func noModelOnDisk() async throws {
        let dir = TemporaryDirectory()
        let engine = FakeLLMBackend()
        let loader = StyleModelLoader(store: store(dir: dir), engine: engine)

        let ready = await loader.isReady()

        #expect(ready == false)
        #expect(await engine.loadedURLs.isEmpty)
        #expect(await engine.unloadCount == 0)
    }

    @Test("installed model: first isReady() starts a background load; warmUp() awaits it; then isReady() is true, and unload happens once the file is removed")
    func installThenRemoveModelFile() async throws {
        let dir = TemporaryDirectory()
        try installStyleModelFile(in: dir)
        let engine = FakeLLMBackend()
        let modelStore = store(dir: dir)
        let loader = StyleModelLoader(store: modelStore, engine: engine)

        let firstReady = await loader.isReady()
        #expect(firstReady == false)   // a load just started; never blocks the caller

        await loader.warmUp()

        let secondReady = await loader.isReady()
        #expect(secondReady == true)
        #expect(await engine.loadedURLs.last?.lastPathComponent == "qwen2.5-3b-instruct-q4_k_m.gguf")

        // Remove the installed file: `state(of:)` no longer reports `.installed`, so
        // `defaultModel(role: .style)` goes nil and `isReady()` unloads the now-stale engine state.
        try FileManager.default.removeItem(at: dir.url.appendingPathComponent(Self.styleModel.fileName))

        let readyAfterRemoval = await loader.isReady()
        #expect(readyAfterRemoval == false)
        #expect(await engine.unloadCount == 1)
        #expect(await engine.loadedURLs.count == 1)   // no model to reload — removal never starts a second load

        // A second `isReady()` with the file still gone must not unload again (idempotent teardown).
        let readyAgain = await loader.isReady()
        #expect(readyAgain == false)
        #expect(await engine.unloadCount == 1)
    }

    @Test("several concurrent isReady() calls plus warmUp() against the same installed model start exactly one background load (plan ruling 4)")
    func concurrentReadyChecksStartExactlyOneLoad() async throws {
        let dir = TemporaryDirectory()
        try installStyleModelFile(in: dir)
        let engine = FakeLLMBackend()
        let loader = StyleModelLoader(store: store(dir: dir), engine: engine)

        // `loadTask == nil` is only ever checked-and-assigned within a single actor-isolated
        // synchronous stretch (no `await` between the check and the assignment in `isReady()`/
        // `warmUp()`), so no interleaving of these four calls can create more than one `Task`.
        async let first = loader.isReady()
        async let second = loader.isReady()
        async let third = loader.isReady()
        await loader.warmUp()
        _ = await (first, second, third)

        #expect(await loader.isReady() == true)
        #expect(await engine.loadedURLs.count == 1)
    }

    /// `StyleEngine` stub whose `load(modelAt:)` suspends until `release()` — mirrors
    /// `FakeLLMBackend.hangs`, but for the load path, to prove the removal path never awaits it
    /// (final review I1) and to exercise the "engine load succeeded after cancellation" branch
    /// in `StyleModelLoader.load(_:)` that had no direct test (M2).
    private actor HangingLoadEngine: StyleEngine {
        private(set) var loadedURLs: [URL] = []
        private(set) var unloadCount = 0
        private var loadWaiters: [CheckedContinuation<Void, Never>] = []
        private var unloadWaiters: [CheckedContinuation<Void, Never>] = []
        private var released = false

        func isReady() async -> Bool { false }
        func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String { "" }

        func load(modelAt url: URL) async throws {
            loadedURLs.append(url)
            if !released {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in loadWaiters.append(continuation) }
            }
        }

        func unload() async {
            unloadCount += 1
            unloadWaiters.forEach { $0.resume() }
            unloadWaiters.removeAll()
        }

        /// Lets the in-flight `load(modelAt:)` call return, as if the engine call had finally
        /// completed (mirrors production: `LlamaEngine.load` is not cancellation-aware).
        func release() {
            released = true
            loadWaiters.forEach { $0.resume() }
            loadWaiters.removeAll()
        }

        /// Suspends until `unload()` has actually been called (or already has) — deterministic
        /// stand-in for a sleep while the resumed load task finishes its cancelled-branch unload.
        func waitForUnload() async {
            if unloadCount > 0 { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in unloadWaiters.append(continuation) }
        }
    }

    @Test("removing the model file while a load is in flight: isReady() returns false immediately without awaiting the load; once released, the engine ends unloaded with no second load (final review I1/M2)")
    func removalDuringLoadDoesNotBlockIsReady() async throws {
        let dir = TemporaryDirectory()
        try installStyleModelFile(in: dir)
        let engine = HangingLoadEngine()
        let loader = StyleModelLoader(store: store(dir: dir), engine: engine)

        let firstReady = await loader.isReady()   // kicks a background load that now hangs inside engine.load(modelAt:)
        #expect(firstReady == false)

        try FileManager.default.removeItem(at: dir.url.appendingPathComponent(Self.styleModel.fileName))

        // The critical assertion: this must return promptly. The stub is released only *after* it —
        // if `cancelLoadAndUnloadIfNeeded()` regressed to awaiting the load, this call would hang.
        let readyAfterRemoval = await loader.isReady()
        #expect(readyAfterRemoval == false)
        #expect(await engine.unloadCount == 0)   // nothing was ever loaded, so there is nothing to unload yet

        await engine.release()
        await engine.waitForUnload()

        #expect(await engine.unloadCount == 1)
        #expect(await engine.loadedURLs.count == 1)   // the cancelled load's own unload never resurrects loadedModelID or starts a second load
        #expect(await loader.isReady() == false)
        #expect(await engine.unloadCount == 1)   // still just the one unload
    }

    @Test("generate before a model is loaded throws modelNotLoaded; once loaded it forwards the prompt")
    func generateBeforeAndAfterLoad() async throws {
        let dir = TemporaryDirectory()
        let engine = FakeLLMBackend(ready: true, reply: "styled text")
        let loader = StyleModelLoader(store: store(dir: dir), engine: engine)
        let prompt = ChatPrompt(system: "system", user: "user text")

        await #expect(throws: LLMError.modelNotLoaded) {
            _ = try await loader.generate(prompt, maxNewTokens: 32)
        }

        try installStyleModelFile(in: dir)
        await loader.warmUp()

        let result = try await loader.generate(prompt, maxNewTokens: 32)
        #expect(result == "styled text")
        #expect(await engine.prompts.last == prompt)
        #expect(await engine.maxTokens.last == 32)
    }
}
