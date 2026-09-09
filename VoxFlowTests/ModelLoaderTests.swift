import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowModels
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("ModelLoader")
struct ModelLoaderTests {
    func store(installed: Bool) async throws -> (ModelStore, TemporaryDirectory) {
        let dir = TemporaryDirectory()
        let model = ModelCatalog.all.first { $0.role == .speech && $0.isDefault }!
        if installed {
            // `ModelStore.state(of:)` counts a model installed only when the file's size matches
            // the catalog entry exactly (`ModelStore.swift`), so the fixture must be that exact
            // size — a sparse file (via `truncate`) gets there without writing ~1.6 GB of real data.
            let url = dir.url.appendingPathComponent(model.fileName)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(model.sizeInBytes))
            try handle.close()
        }
        let store = ModelStore(directory: dir.url, downloader: FakeModelDownloader(), freeSpace: FakeFreeSpace(available: 1 << 40),
                               settings: InMemoryKeyValueStore())
        return (store, dir)
    }

    @Test("readiness: not installed → size; installed → installedNotLoaded; after ensureLoaded → loaded (engine loaded once)")
    func readiness() async throws {
        // Both directories are kept alive (named, not `_`) for the rest of the test: `TemporaryDirectory`
        // deletes its directory in `deinit`, and discarding it would remove the fixture file the
        // moment `store(installed:)` returns, before `ModelLoader` ever reads it back.
        let (missing, missingDir) = try await store(installed: false)
        let engine = FakeSpeechEngine(script: [])
        #expect(await ModelLoader(store: missing, engine: engine).readiness() == .notInstalled(sizeBytes: 1_624_555_275))

        let (present, presentDir) = try await store(installed: true)
        let loader = ModelLoader(store: present, engine: engine)
        #expect(await loader.readiness() == .installedNotLoaded)
        // M-9: `ensureLoaded()` returns the `ModelDescriptor` it ensured — callers that need to know
        // which model is loaded (e.g. `LazyModelFileTranscriber`) shouldn't have to look it up again.
        let defaultModel = ModelCatalog.all.first { $0.role == .speech && $0.isDefault }!
        let first = try await loader.ensureLoaded()
        let second = try await loader.ensureLoaded()
        #expect(first.id == defaultModel.id && second.id == defaultModel.id)
        #expect(await loader.readiness() == .loaded)
        #expect(await engine.loadedModelURL?.lastPathComponent == "ggml-large-v3-turbo.bin")
        _ = missingDir
        _ = presentDir
    }
}
