import Foundation
import Synchronization
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
        let engine = HangingLoadEngine()
        await engine.release()
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
        await engine.waitForUnload()
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

    private actor HangingUnloadEngine: StyleEngine {
        let unloadEntered = Gate()
        let releaseUnload = Gate()
        private(set) var ready = false

        func isReady() async -> Bool { ready }
        func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String { "" }
        func load(modelAt url: URL) async throws { ready = true }
        func unload() async {
            await unloadEntered.open()
            await releaseUnload.wait()
            ready = false
        }
    }

    @Test("isReady returns while native unload is still in flight")
    func removalNeverAwaitsNativeUnload() async throws {
        let dir = TemporaryDirectory()
        try installStyleModelFile(in: dir)
        let engine = HangingUnloadEngine()
        let loader = StyleModelLoader(store: store(dir: dir), engine: engine)
        await loader.warmUp()
        try FileManager.default.removeItem(at: dir.url.appendingPathComponent(Self.styleModel.fileName))

        let readiness = Task { await loader.isReady() }
        await engine.unloadEntered.wait()
        let returnedBeforeUnload = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await readiness.value; return true }
            group.addTask { try? await Task.sleep(for: .milliseconds(250)); return false }
            let first = await group.next()!
            await engine.releaseUnload.open()
            group.cancelAll()
            return first
        }

        #expect(returnedBeforeUnload)
        #expect(await readiness.value == false)
    }

    private actor RestartedLoadEngine: StyleEngine {
        let firstLoadEntered = Gate()
        let secondLoadEntered = Gate()
        let releaseFirstLoad = Gate()
        private(set) var ready = false
        private(set) var loadCount = 0
        private(set) var unloadCount = 0
        private(set) var loadedURLs: [URL] = []

        func isReady() async -> Bool { ready }
        func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String { "" }
        func load(modelAt url: URL) async throws {
            loadCount += 1
            loadedURLs.append(url)
            let ordinal = loadCount
            if ordinal == 1 {
                await firstLoadEntered.open()
                await releaseFirstLoad.wait()
            } else {
                await secondLoadEntered.open()
            }
            ready = true
        }
        func unload() async { unloadCount += 1; ready = false }
    }

    @Test("a cancelled load cleans up before its replacement takes ownership")
    func staleLoadCannotUnloadReplacement() async throws {
        let dir = TemporaryDirectory()
        try installStyleModelFile(in: dir)
        let engine = RestartedLoadEngine()
        let loader = StyleModelLoader(store: store(dir: dir), engine: engine)
        #expect(await loader.isReady() == false)
        await engine.firstLoadEntered.wait()

        let modelURL = dir.url.appendingPathComponent(Self.styleModel.fileName)
        try FileManager.default.removeItem(at: modelURL)
        #expect(await loader.isReady() == false)
        try installStyleModelFile(in: dir)
        #expect(await loader.isReady() == false)

        // The old implementation starts the replacement immediately. The fixed implementation
        // waits for the stale load and its unload, but this bounded probe releases both paths.
        let replacementStartedEarly = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await engine.secondLoadEntered.wait(); return true }
            group.addTask { try? await Task.sleep(for: .milliseconds(250)); return false }
            let first = await group.next()!
            await engine.releaseFirstLoad.open()
            group.cancelAll()
            return first
        }
        await loader.warmUp()

        #expect(replacementStartedEarly == false)
        #expect(await engine.loadCount == 2)
        #expect(await engine.unloadCount == 1)
        #expect(await engine.ready)
        #expect(await loader.isReady())
    }

    @Test("changing the default during a held load replaces that load before warm-up returns")
    func changedDefaultReplacesHeldLoad() async throws {
        let first = ModelDescriptor(
            id: "style-a", displayName: "A", role: .style,
            downloadURL: URL(string: "https://example.invalid/a.gguf")!, sizeInBytes: 1,
            sha256: "a", languagesSummary: "", isDefault: true
        )
        let second = ModelDescriptor(
            id: "style-b", displayName: "B", role: .style,
            downloadURL: URL(string: "https://example.invalid/b.gguf")!, sizeInBytes: 1,
            sha256: "b", languagesSummary: "", isDefault: false
        )
        let dir = TemporaryDirectory()
        try Data([0]).write(to: dir.url.appendingPathComponent(first.fileName))
        try Data([0]).write(to: dir.url.appendingPathComponent(second.fileName))
        let modelStore = ModelStore(
            directory: dir.url, catalog: [first, second], downloader: FakeModelDownloader(),
            freeSpace: FakeFreeSpace(available: 10_000), settings: InMemoryKeyValueStore()
        )
        let engine = RestartedLoadEngine()
        let loader = StyleModelLoader(store: modelStore, engine: engine)

        #expect(await loader.isReady() == false)
        await engine.firstLoadEntered.wait()
        try await modelStore.setDefault(id: second.id)

        #expect(await loader.isReady() == false)
        #expect(await loader.loadingModelID == second.id)
        await engine.releaseFirstLoad.open()
        await loader.warmUp()

        #expect(await engine.loadedURLs.map(\.lastPathComponent) == [first.fileName, second.fileName])
        #expect(await engine.unloadCount == 1)
        #expect(await engine.ready)
        #expect(await loader.loadedModelID == second.id)
    }

    @Test("successful load and use each arm the five-minute idle lease")
    func successfulActivityRefreshesIdleLease() async throws {
        let dir = TemporaryDirectory()
        try installStyleModelFile(in: dir)
        let clock = FakeClock()
        let engine = FakeLLMBackend(ready: true, reply: "styled")
        let loader = StyleModelLoader(store: store(dir: dir), engine: engine, clock: clock)

        #expect(StyleModelLoader.defaultIdleInterval == 300)
        await loader.warmUp()
        #expect(await loader.idleTimerRevision == 1)

        let prompt = ChatPrompt(system: "system", user: "draft")
        #expect(try await loader.generate(prompt, maxNewTokens: 8) == "styled")
        #expect(await loader.idleTimerRevision == 2)
    }

    private final class AdvancingClock: MonotonicClock, Sendable {
        private let time = Mutex<TimeInterval>(0)
        func now() -> TimeInterval { time.withLock { $0 } }
        func advance(by seconds: TimeInterval) { time.withLock { $0 += seconds } }
        func sleep(for seconds: TimeInterval) async throws {
            try Task.checkCancellation()
            time.withLock { $0 += seconds }
        }
    }

    @Test("a delayed timer task still unloads at the activity's original deadline")
    func delayedTimerStartUsesAbsoluteDeadline() async throws {
        let dir = TemporaryDirectory()
        try installStyleModelFile(in: dir)
        let clock = AdvancingClock()
        let startTimer = Gate()
        let engine = HangingLoadEngine()
        await engine.release()
        let loader = StyleModelLoader(
            store: store(dir: dir), engine: engine, clock: clock, idleInterval: 300,
            idleTaskFactory: { operation in
                Task { await startTimer.wait(); await operation() }
            }
        )

        await loader.warmUp()
        clock.advance(by: 300) // child task has not started, but the activity lease has expired
        await startTimer.open()
        await engine.waitForUnload()

        #expect(clock.now() == 300)
        #expect(await engine.unloadCount == 1)
        #expect(await loader.loadedModelID == nil)
    }

    @Test("idle expiry unloads once and the next readiness check reloads lazily")
    func idleExpiryAndLazyReload() async throws {
        let dir = TemporaryDirectory()
        try installStyleModelFile(in: dir)
        let clock = FakeClock()
        let engine = HangingLoadEngine()
        await engine.release()
        let loader = StyleModelLoader(
            store: store(dir: dir), engine: engine, clock: clock, idleInterval: 10
        )

        await loader.warmUp()
        await clock.waitForSleepers(1)
        await clock.advance(by: 10)
        await engine.waitForUnload()
        #expect(await loader.loadedModelID == nil)

        #expect(await loader.isReady() == false)
        await loader.warmUp()
        #expect(await loader.isReady())
        #expect(await engine.loadedURLs.count == 2)
        #expect(await engine.unloadCount == 1)
    }

    @Test("successful generation replaces the stale lease deadline")
    func successfulGenerationRefreshesDeadline() async throws {
        let dir = TemporaryDirectory()
        try installStyleModelFile(in: dir)
        let clock = FakeClock()
        let engine = HangingLoadEngine()
        await engine.release()
        let loader = StyleModelLoader(
            store: store(dir: dir), engine: engine, clock: clock, idleInterval: 10
        )
        await loader.warmUp()
        await clock.waitForSleepers(1)
        await clock.advance(by: 9)

        _ = try await loader.generate(ChatPrompt(system: "system", user: "draft"), maxNewTokens: 8)
        await clock.waitForSleepers(1)
        await clock.advance(by: 1)
        #expect(await engine.unloadCount == 0)

        await clock.advance(by: 9)
        await engine.waitForUnload()
        #expect(await engine.unloadCount == 1)
    }

    @Test("idle expiry cannot unload an active generation")
    func activeGenerationDefersIdleLease() async throws {
        let dir = TemporaryDirectory()
        try installStyleModelFile(in: dir)
        let clock = FakeClock()
        let engine = ContendedStyleEngine()
        let loader = StyleModelLoader(
            store: store(dir: dir), engine: engine, clock: clock, idleInterval: 10
        )
        await loader.warmUp()
        await clock.waitForSleepers(1)

        let generation = Task {
            try await loader.generate(ChatPrompt(system: "system", user: "draft"), maxNewTokens: 8)
        }
        await engine.entered.wait()
        #expect(clock.sleeperCount == 0)
        await clock.advance(by: 10)
        #expect(await engine.unloadCount == 0)

        await engine.release.open()
        #expect(try await generation.value == "styled text")
        await clock.waitForSleepers(1)
        await clock.advance(by: 10)
        await engine.unloadCalled.wait()
        #expect(await engine.unloadCount == 1)
    }

    @Test("concurrent ready callers cannot queue another generation behind native work", .timeLimit(.minutes(1)))
    func busyGenerationFallsBackImmediately() async throws {
        let dir = TemporaryDirectory()
        try installStyleModelFile(in: dir)
        let engine = ContendedStyleEngine()
        let loader = StyleModelLoader(store: store(dir: dir), engine: engine)
        await loader.warmUp()
        // Both callers can observe ready before either calls generate; the generate-side claim
        // must decide ownership atomically, independently of the earlier advisory readiness.
        #expect(await loader.isReady())
        #expect(await loader.isReady())
        let prompt = ChatPrompt(system: "system", user: "we should meet tomorrow")
        let first = Task { try await loader.generate(prompt, maxNewTokens: 32) }
        await engine.entered.wait()
        #expect(await loader.isReady() == false)
        await #expect(throws: LLMError.backendBusy) {
            _ = try await loader.generate(prompt, maxNewTokens: 32)
        }
        #expect(await engine.calls == 1)
        await engine.release.open()
        #expect(try await first.value == "styled text")
        #expect(await loader.isReady())
        #expect(try await loader.generate(prompt, maxNewTokens: 32) == "styled text")
        await engine.failNext()
        await #expect(throws: LLMError.cancelled) {
            _ = try await loader.generate(prompt, maxNewTokens: 32)
        }
        #expect(await loader.isReady()) // throwing generation must release ownership too
    }

    private actor ContendedStyleEngine: StyleEngine {
        let entered = Gate(), release = Gate()
        private(set) var calls = 0
        private(set) var unloadCount = 0
        let unloadCalled = Gate()
        private var fail = false
        func isReady() async -> Bool { true }
        func load(modelAt url: URL) async throws {}
        func unload() async { unloadCount += 1; await unloadCalled.open() }
        func failNext() { fail = true }
        func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String {
            calls += 1
            if fail { fail = false; throw LLMError.cancelled }
            if calls == 1 { await entered.open(); await release.wait() }
            return "styled text"
        }
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
