import Foundation
import VoxFlowCore
import VoxFlowDictation
import VoxFlowModels

/// The one place that knows which speech model the engine holds (ruling 9). Files and dictation share it.
actor ModelLoader {
    private let store: ModelStore
    private let engine: any SpeechEngine
    private(set) var loadedModelID: String?

    init(store: ModelStore, engine: any SpeechEngine) { self.store = store; self.engine = engine }

    func readiness() async -> ModelReadiness {
        guard let model = await store.defaultModel(role: .speech) else {
            let size = ModelCatalog.all.first { $0.role == .speech && $0.isDefault }?.sizeInBytes ?? 0
            return .notInstalled(sizeBytes: size)
        }
        return loadedModelID == model.id ? .loaded : .installedNotLoaded
    }

    /// Loads the default speech model if it is not the one already in the engine, and returns the
    /// `ModelDescriptor` it ensured (M-9: callers that need to know which model is loaded — e.g.
    /// `LazyModelFileTranscriber` — no longer have to look it up a second time via `store.defaultModel`,
    /// which could disagree with this result if the default changed between the two calls).
    @discardableResult
    func ensureLoaded() async throws -> ModelDescriptor {
        guard let model = await store.defaultModel(role: .speech) else { throw FileTranscriptionError.noModelInstalled }
        guard loadedModelID != model.id else { return model }
        do { try await engine.load(modelAt: store.directory.appendingPathComponent(model.fileName)) }
        catch { throw FileTranscriptionError.engineFailed("model load failed: \(error)") }
        loadedModelID = model.id
        return model
    }
}
