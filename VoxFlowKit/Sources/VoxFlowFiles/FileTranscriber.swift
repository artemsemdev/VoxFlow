import Foundation
import VoxFlowCore

/// Decode → (auto language) → transcribe → `TranscriptDocument`. One file per call.
public struct FileTranscriber: FileTranscribing {
    static let decodeShare = 0.05

    private let decoder: any AudioDecoding
    private let engine: any SpeechEngine
    private let modelID: String
    private let now: @Sendable () -> Date

    public init(decoder: any AudioDecoding, engine: any SpeechEngine, modelID: String,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.decoder = decoder
        self.engine = engine
        self.modelID = modelID
        self.now = now
    }

    public func transcribe(_ url: URL, options: TranscriptionOptions,
                           progress: @Sendable @escaping (Double) -> Void) async throws -> TranscriptDocument {
        try Task.checkCancellation()
        let started = now()
        let audio: AudioSamples
        do {
            audio = try decoder.decode(url)
        } catch let error as AudioDecodingError {
            switch error {
            case .unsupportedType(let ext): throw FileTranscriptionError.unsupportedType(ext)
            case .fileNotFound(let missing): throw FileTranscriptionError.decodeFailed("file not found: \(missing.lastPathComponent)")
            case .decodeFailed(let reason): throw FileTranscriptionError.decodeFailed(reason)
            }
        }
        progress(Self.decodeShare)

        var options = options
        do {
            if options.language == nil {
                options.language = try await engine.detectLanguage(in: audio).code
            }
            var segments: [TranscriptSegment] = []
            for try await event in engine.transcribe(audio, options: options) {
                switch event {
                case .segment(let segment): segments.append(segment)
                case .progress(let value): progress(Self.decodeShare + (1 - Self.decodeShare) * min(max(value, 0), 1))
                }
            }
            try Task.checkCancellation()
            progress(1)
            let finished = now()
            return TranscriptDocument(sourceURL: url, transcript: Transcript(segments: segments, language: options.language),
                                      modelID: modelID, audioDuration: audio.duration,
                                      processingTime: finished.timeIntervalSince(started), createdAt: finished)
        } catch SpeechEngineError.modelNotLoaded {
            throw FileTranscriptionError.noModelInstalled
        } catch SpeechEngineError.cancelled {
            throw FileTranscriptionError.cancelled
        } catch is CancellationError {
            throw FileTranscriptionError.cancelled
        } catch let error as FileTranscriptionError {
            throw error
        } catch {
            throw FileTranscriptionError.engineFailed(String(describing: error))
        }
    }
}
