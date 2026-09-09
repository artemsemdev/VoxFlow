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
    private static let log = Logger(subsystem: "dev.artemsem.voxflow", category: "style-model")

    init(store: ModelStore, engine: any StyleEngine) { self.store = store; self.engine = engine }

    func isReady() async -> Bool {
        guard let model = await store.defaultModel(role: .style) else {
            await cancelLoadAndUnloadIfNeeded()
            return false
        }
        if loadedModelID == model.id { return true }
        if loadTask == nil { loadTask = Task { await self.load(model) } }
        return false
    }

    /// Launch hook: same as `isReady()` but awaited, so the first dictation after launch can already
    /// use the LLM once the Metal shaders and weights are in memory.
    func warmUp() async {
        guard let model = await store.defaultModel(role: .style), loadedModelID != model.id else { return }
        if loadTask == nil { loadTask = Task { await self.load(model) } }
        await loadTask?.value
    }

    func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String {
        guard loadedModelID != nil else { throw LLMError.modelNotLoaded }
        return try await engine.generate(prompt, maxNewTokens: maxNewTokens)
    }

    private func load(_ model: ModelDescriptor) async {
        defer { loadTask = nil }
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

    /// Cancels and awaits any in-flight load *before* touching the engine, so `engine.unload()` never
    /// races an in-flight `engine.load(modelAt:)` — without this, two callers that both observe "no
    /// default model" could both call `engine.unload()` (a load's own cancellation-triggered unload
    /// above, plus this one), or a load could finish and resurrect `loadedModelID` for a model that's
    /// no longer installed, right after this returned.
    private func cancelLoadAndUnloadIfNeeded() async {
        loadTask?.cancel()
        await loadTask?.value
        loadTask = nil
        guard loadedModelID != nil else { return }
        loadedModelID = nil   // clear *before* the suspension: a second caller resuming here sees nothing left to unload
        await engine.unload()
    }
}
