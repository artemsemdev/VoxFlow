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
