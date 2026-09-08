import Foundation
import VoxFlowCore
import VoxFlowFiles
import VoxFlowModels

/// Resolves the default speech model per job, loads it into the engine when it changed, then transcribes.
actor LazyModelFileTranscriber: FileTranscribing {
    private let store: ModelStore
    private let engine: any SpeechEngine
    private let decoder: any AudioDecoding
    private var loadedModelID: String?

    init(store: ModelStore, engine: any SpeechEngine, decoder: any AudioDecoding) {
        self.store = store
        self.engine = engine
        self.decoder = decoder
    }

    func transcribe(_ url: URL, options: TranscriptionOptions,
                    progress: @Sendable @escaping (Double) -> Void) async throws -> TranscriptDocument {
        guard let model = await store.defaultModel(role: .speech) else { throw FileTranscriptionError.noModelInstalled }
        if loadedModelID != model.id {
            do {
                try await engine.load(modelAt: store.directory.appendingPathComponent(model.fileName))
            } catch {
                throw FileTranscriptionError.engineFailed("model load failed: \(error)")
            }
            loadedModelID = model.id
        }
        return try await FileTranscriber(decoder: decoder, engine: engine, modelID: model.id)
            .transcribe(url, options: options, progress: progress)
    }
}
