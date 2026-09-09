import Foundation
import VoxFlowCore
import VoxFlowFiles
import VoxFlowModels

/// Resolves the default speech model per job via the shared `ModelLoader`, then transcribes.
actor LazyModelFileTranscriber: FileTranscribing {
    private let loader: ModelLoader
    private let store: ModelStore
    private let engine: any SpeechEngine
    private let decoder: any AudioDecoding

    init(loader: ModelLoader, store: ModelStore, engine: any SpeechEngine, decoder: any AudioDecoding) {
        self.loader = loader
        self.store = store
        self.engine = engine
        self.decoder = decoder
    }

    func transcribe(_ url: URL, options: TranscriptionOptions,
                    progress: @Sendable @escaping (Double) -> Void) async throws -> TranscriptDocument {
        // M-9: use the model `ensureLoaded()` itself ensured, rather than looking the default up a
        // second time — the two could disagree if the default changed between the two calls.
        let model = try await loader.ensureLoaded()
        return try await FileTranscriber(decoder: decoder, engine: engine, modelID: model.id)
            .transcribe(url, options: options, progress: progress)
    }
}
