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
    private(set) var loadingModelID: String?
    /// Serializes native loads and unloads without making readiness checks wait for either one.
    /// In particular, a replacement load must start only after a cancelled predecessor has been
    /// unloaded, otherwise the predecessor's cleanup can unload the replacement model.
    private var lifecycleTask: Task<Void, Never>?
    // Do not queue a short-budget dictation behind another native generation: a queued native
    // continuation cannot observe cancellation until the older operation leaves the serial queue.
    private var generationInFlight = false
    /// Captured by each load. Cancellation advances it immediately, so stale completions cannot
    /// clear or publish ownership while their cleanup and replacement remain queued.
    private var loadGeneration = 0
    private static let log = Logger(subsystem: "dev.artemsem.voxflow", category: "style-model")

    init(store: ModelStore, engine: any StyleEngine) { self.store = store; self.engine = engine }

    func isReady() async -> Bool {
        guard !generationInFlight else { return false }
        let model = await store.defaultModel(role: .style)
        guard !generationInFlight else { return false }
        guard let model else {
            scheduleUnloadIfNeeded()
            return false
        }
        if loadedModelID == model.id { return true }
        ensureLoad(of: model)
        return false
    }

    /// Launch hook: same as `isReady()` but awaited, so the first dictation after launch can already
    /// use the LLM once the Metal shaders and weights are in memory.
    func warmUp() async {
        guard let model = await store.defaultModel(role: .style), loadedModelID != model.id else { return }
        ensureLoad(of: model)
        await loadTask?.value
    }

    func generate(_ prompt: ChatPrompt, maxNewTokens: Int) async throws -> String {
        guard loadedModelID != nil else { throw LLMError.modelNotLoaded }
        guard !generationInFlight else { throw LLMError.backendBusy }
        generationInFlight = true
        defer { generationInFlight = false }
        return try await engine.generate(prompt, maxNewTokens: maxNewTokens)
    }

    private func ensureLoad(of model: ModelDescriptor) {
        guard loadingModelID != model.id else { return }
        scheduleUnloadIfNeeded()
        startLoad(model)
    }

    private func startLoad(_ model: ModelDescriptor) {
        loadGeneration += 1
        let generation = loadGeneration
        let predecessor = lifecycleTask
        let task = Task {
            await predecessor?.value
            guard !Task.isCancelled else { return }
            await self.load(model, generation: generation)
        }
        loadTask = task
        loadingModelID = model.id
        lifecycleTask = task
    }

    private func load(_ model: ModelDescriptor, generation: Int) async {
        // Only clear `loadTask` if a newer load hasn't since replaced it — lifecycle cancellation
        // may already have forgotten this task (without waiting for it) by the time it resumes here.
        defer {
            if loadGeneration == generation {
                loadTask = nil
                loadingModelID = nil
            }
        }
        do {
            try await engine.load(modelAt: store.directory.appendingPathComponent(model.fileName))
            // A cancelled, non-cancellation-aware native load may still finish. Clean it up inside
            // this lifecycle operation, before the chained replacement is allowed to start.
            guard !Task.isCancelled, loadGeneration == generation else {
                await engine.unload()
                return
            }
            loadedModelID = model.id
        } catch {
            guard loadGeneration == generation else { return }
            Self.log.error("style model load failed: \(String(describing: error))")
            loadedModelID = nil
        }
    }

    /// Cancels logical ownership immediately while native cleanup stays on the lifecycle chain.
    /// `isReady()` must never await native load or unload work.
    private func scheduleUnloadIfNeeded() {
        let cancelledLoad = loadTask != nil
        let loadedModel = loadedModelID != nil
        guard cancelledLoad || loadedModel else { return }
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        loadingModelID = nil
        loadedModelID = nil

        // An in-flight load owns its cleanup inside `load`. A task cancelled before entering the
        // engine touched no native state, so it needs no extra unload either.
        guard !cancelledLoad, loadedModel else { return }

        let predecessor = lifecycleTask
        let task = Task {
            await predecessor?.value
            await self.engine.unload()
        }
        lifecycleTask = task
    }
}
