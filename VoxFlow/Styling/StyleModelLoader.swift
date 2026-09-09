import Foundation
import OSLog
import VoxFlowCore
import VoxFlowModels

/// Lazy owner of the style model (plan ruling 4). Implements `LLMBackend` for `LlamaStyler`: ready
/// only when the default `.style` model from `ModelStore` is loaded into `engine`; an installed but
/// unloaded model starts one background load and reports not-ready; a removed model is unloaded.
actor StyleModelLoader: LLMBackend {
    private let store: ModelStore
    private let engine: any StyleEngine
    private(set) var loadedModelID: String?
    private var loadTask: Task<Void, Never>?
    /// Bumped every time a new load `Task` is created, and captured by that task. Lets
    /// `load(_:generation:)`'s `defer` tell "I am still the current `loadTask`" from "a newer load
    /// has already replaced me" without comparing `Task` values (final review I1) — needed because
    /// `cancelLoadAndUnloadIfNeeded()` now forgets `loadTask` immediately, without awaiting it, so a
    /// cancelled load can still be running when a fresh one starts.
    private var loadGeneration = 0
    private static let log = Logger(subsystem: "dev.artemsem.voxflow", category: "style-model")

    init(store: ModelStore, engine: any StyleEngine) { self.store = store; self.engine = engine }

    func isReady() async -> Bool {
        guard let model = await store.defaultModel(role: .style) else {
            await cancelLoadAndUnloadIfNeeded()
            return false
        }
        if loadedModelID == model.id { return true }
        if loadTask == nil { startLoad(model) }
        return false
    }

    /// Launch hook: same as `isReady()` but awaited, so the first dictation after launch can already
    /// use the LLM once the Metal shaders and weights are in memory.
    func warmUp() async {
        guard let model = await store.defaultModel(role: .style), loadedModelID != model.id else { return }
        if loadTask == nil { startLoad(model) }
        await loadTask?.value
    }

    func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String {
        guard loadedModelID != nil else { throw LLMError.modelNotLoaded }
        return try await engine.generate(prompt, maxNewTokens: maxNewTokens)
    }

    private func startLoad(_ model: ModelDescriptor) {
        loadGeneration += 1
        let generation = loadGeneration
        loadTask = Task { await self.load(model, generation: generation) }
    }

    private func load(_ model: ModelDescriptor, generation: Int) async {
        // Only clear `loadTask` if a newer load hasn't since replaced it — `cancelLoadAndUnloadIfNeeded()`
        // may already have forgotten this task (without waiting for it) by the time it resumes here.
        defer { if loadGeneration == generation { loadTask = nil } }
        do {
            try await engine.load(modelAt: store.directory.appendingPathComponent(model.fileName))
            // The wrapping `Task` may have been cancelled (the model was removed, or `isReady()`
            // found a different default) while `engine.load` was in flight — `engine.load` itself
            // isn't cancellation-aware, so it can still succeed after that. Undo it rather than
            // publish a model that's no longer the one to serve.
            guard !Task.isCancelled else {
                await engine.unload()
                loadedModelID = nil
                return
            }
            loadedModelID = model.id
        } catch {
            Self.log.error("style model load failed: \(String(describing: error))")
            loadedModelID = nil
        }
    }

    /// Non-blocking (final review I1): cancels any in-flight load and forgets it immediately,
    /// *without* awaiting it — `LlamaEngine.load` isn't cancellation-aware, so awaiting it here could
    /// stall a dictation's `isReady()` check for an entire first-run model load (~20 s). If nothing
    /// is loaded yet, there is nothing to unload and this returns right away. If a model was already
    /// loaded, that `engine.unload()` call is on an already-resident model — measured fast, so it's
    /// still safe to await. A load that's still in flight when cancelled is unloaded by
    /// `load(_:generation:)`'s own cancelled branch above, once the (non-cancellation-aware)
    /// `engine.load` call eventually returns on its own.
    private func cancelLoadAndUnloadIfNeeded() async {
        loadTask?.cancel()
        loadTask = nil
        guard loadedModelID != nil else { return }
        loadedModelID = nil   // clear *before* the suspension: a second caller resuming here sees nothing left to unload
        await engine.unload()
    }
}
