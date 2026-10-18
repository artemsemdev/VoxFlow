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

    @Test("concurrent callers share one load and cancelling one waiter leaves the shared load active")
    func sharedLoadSurvivesOneWaiterCancellation() async throws {
        let (store, directory) = try await store(installed: true)
        let engine = HeldLoadEngine()
        let loader = ModelLoader(store: store, engine: engine)
        var events = await loader.subscribe().makeAsyncIterator()
        let notifications = AsyncStream<String>.makeStream()

        let first = Task { try await loader.ensureLoaded { notifications.continuation.yield($0) } }
        var loading = notifications.stream.makeAsyncIterator()
        #expect(await loading.next() == "whisper-large-v3-turbo")
        await engine.waitUntilEntered()
        #expect(await events.next() == .started("whisper-large-v3-turbo"))

        let second = Task { try await loader.ensureLoaded { notifications.continuation.yield($0) } }
        #expect(await loading.next() == "whisper-large-v3-turbo")
        first.cancel()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        #expect(await loader.loadingModelID == "whisper-large-v3-turbo")

        await engine.release()
        #expect(try await second.value.id == "whisper-large-v3-turbo")
        #expect(await engine.loadCount == 1)
        #expect(await events.next() == .finished("whisper-large-v3-turbo"))
        #expect(await loader.loadingModelID == nil)
        _ = directory
    }

    @Test("cancelling the sole waiter cancels its load and publishes one terminal event")
    func soleWaiterCancellation() async throws {
        let (store, directory) = try await store(installed: true)
        let engine = HeldLoadEngine()
        let loader = ModelLoader(store: store, engine: engine)
        var events = await loader.subscribe().makeAsyncIterator()
        let operation = Task { try await loader.ensureLoaded() }
        await engine.waitUntilEntered()
        #expect(await events.next() == .started("whisper-large-v3-turbo"))

        operation.cancel()
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(await events.next() == .finished("whisper-large-v3-turbo"))
        #expect(await loader.loadingModelID == nil)
        #expect(await loader.readiness() == .installedNotLoaded)

        #expect(try await loader.ensureLoaded().id == "whisper-large-v3-turbo")
        #expect(await events.next() == .started("whisper-large-v3-turbo"))
        #expect(await events.next() == .finished("whisper-large-v3-turbo"))
        #expect(await engine.loadCount == 2)
        #expect(await loader.readiness() == .loaded)
        _ = directory
    }

    @Test("cancellation inside the starter callback cannot leave a zero-waiter load active")
    func starterCancelledBeforeWaitRegistration() async throws {
        let (store, directory) = try await store(installed: true)
        let engine = HeldLoadEngine()
        let loader = ModelLoader(store: store, engine: engine)
        var events = await loader.subscribe().makeAsyncIterator()

        let operation = Task {
            try await loader.ensureLoaded { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(await events.next() == .started("whisper-large-v3-turbo"))
        await engine.waitUntilEntered()
        #expect(await events.next() == .finished("whisper-large-v3-turbo"))
        #expect(await engine.cancellationCount == 1)
        #expect(await loader.loadingModelID == nil)

        #expect(try await loader.ensureLoaded().id == "whisper-large-v3-turbo")
        #expect(await events.next() == .started("whisper-large-v3-turbo"))
        #expect(await events.next() == .finished("whisper-large-v3-turbo"))
        #expect(await loader.readiness() == .loaded)
        _ = directory
    }
}

private actor HeldLoadEngine: SpeechEngine {
    private let entered = Gate()
    private let hold = Gate()
    private(set) var loadCount = 0
    private(set) var cancellationCount = 0

    func waitUntilEntered() async { await entered.wait() }
    func release() async { await hold.open() }

    func load(modelAt url: URL) async throws {
        loadCount += 1
        await entered.open()
        do {
            try await withTaskCancellationHandler {
                await hold.wait()
                try Task.checkCancellation()
            } onCancel: {
                Task { await self.hold.open() }
            }
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }

    func detectLanguage(in audio: AudioSamples) async throws -> LanguageDetection {
        LanguageDetection(code: "en", confidence: 1)
    }

    nonisolated func transcribe(_ audio: AudioSamples,
                               options: TranscriptionOptions) -> AsyncThrowingStream<SegmentEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
