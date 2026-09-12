import Foundation
import VoxFlowCore
import VoxFlowDictation
import VoxFlowModels

/// The one place that knows which speech model the engine holds (ruling 9). Files and dictation share it.
actor ModelLoader {
    enum Event: Sendable, Equatable { case started(String), finished(String) }

    private let store: ModelStore
    private let engine: any SpeechEngine
    private(set) var loadedModelID: String?
    private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]
    private(set) var loadingModelID: String?
    private var activeLoad: ActiveLoad?
    private var loadTask: Task<Void, Never>?

    private struct ActiveLoad {
        let token: UUID
        let model: ModelDescriptor
        var waiters: [UUID: CheckedContinuation<ModelDescriptor, any Error>] = [:]
    }

    private enum LoadOutcome: Sendable {
        case success(ModelDescriptor)
        case cancelled
        case failure(FileTranscriptionError)
    }

    init(store: ModelStore, engine: any SpeechEngine) { self.store = store; self.engine = engine }

    func readiness() async -> ModelReadiness {
        guard let model = await store.defaultModel(role: .speech) else {
            let size = ModelCatalog.all.first { $0.role == .speech && $0.isDefault }?.sizeInBytes ?? 0
            return .notInstalled(sizeBytes: size)
        }
        return loadedModelID == model.id ? .loaded : .installedNotLoaded
    }

    func subscribe() -> AsyncStream<Event> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(2))
        subscribers[id] = continuation
        continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
        return stream
    }

    /// Loads the default speech model once across concurrent Files/dictation callers. Each caller
    /// can cancel its own wait; the native load is cancelled only after its last waiter leaves.
    @discardableResult
    func ensureLoaded(onLoading: @Sendable (String) -> Void = { _ in }) async throws -> ModelDescriptor {
        try Task.checkCancellation()
        guard let model = await store.defaultModel(role: .speech) else { throw FileTranscriptionError.noModelInstalled }
        guard loadedModelID != model.id else { return model }
        let modelURL = await store.directory.appendingPathComponent(model.fileName)
        try Task.checkCancellation()

        if let activeLoad {
            if activeLoad.model.id == model.id {
                onLoading(model.id)
                return try await waitForLoad(token: activeLoad.token)
            }
            // One engine cannot load two models concurrently. Let the old default settle, then
            // resolve the current default again; its failure must not poison a different model.
            do { _ = try await waitForLoad(token: activeLoad.token) }
            catch is CancellationError where Task.isCancelled { throw CancellationError() }
            catch {}
            return try await ensureLoaded(onLoading: onLoading)
        }

        let token = UUID()
        activeLoad = ActiveLoad(token: token, model: model)
        loadingModelID = model.id
        onLoading(model.id)
        publish(.started(model.id))

        loadTask = Task {
            let outcome: LoadOutcome
            do {
                try await engine.load(modelAt: modelURL)
                outcome = .success(model)
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failure(.engineFailed("model load failed: \(error)"))
            }
            completeLoad(token: token, outcome: outcome)
        }
        return try await waitForLoad(token: token)
    }

    private func waitForLoad(token: UUID) async throws -> ModelDescriptor {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard activeLoad?.token == token else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                activeLoad?.waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, token: token) }
        }
    }

    private func cancelWaiter(id: UUID, token: UUID) {
        guard activeLoad?.token == token else { return }
        activeLoad?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if activeLoad?.waiters.isEmpty == true { loadTask?.cancel() }
    }

    private func completeLoad(token: UUID, outcome: LoadOutcome) {
        guard let load = activeLoad, load.token == token else { return }
        activeLoad = nil
        loadTask = nil
        loadingModelID = nil
        if case .success(let model) = outcome { loadedModelID = model.id }
        publish(.finished(load.model.id))
        for continuation in load.waiters.values {
            switch outcome {
            case .success(let model): continuation.resume(returning: model)
            case .cancelled: continuation.resume(throwing: CancellationError())
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }
    private func publish(_ event: Event) { subscribers.values.forEach { $0.yield(event) } }
}
