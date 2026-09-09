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
            if loadedModelID != nil { await unload() }
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
            loadedModelID = model.id
        } catch {
            Self.log.error("style model load failed: \(String(describing: error))")
            loadedModelID = nil
        }
    }

    private func unload() async {
        await engine.unload()
        loadedModelID = nil
    }
}
