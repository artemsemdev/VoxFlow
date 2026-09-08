import Foundation
import VoxFlowCore

/// Scripted `SpeechEngine` for callers' tests. Replays `script` for every transcription.
public actor FakeSpeechEngine: SpeechEngine {
    public private(set) var isLoaded = false
    public private(set) var loadedModelURL: URL?
    public private(set) var transcribeCalls = 0
    public private(set) var lastOptions: TranscriptionOptions?
    public var script: [SegmentEvent]
    public var detection: LanguageDetection

    public init(script: [SegmentEvent], detection: LanguageDetection = LanguageDetection(code: "en", confidence: 0.99)) {
        self.script = script
        self.detection = detection
    }

    public func load(modelAt url: URL) async throws {
        isLoaded = true
        loadedModelURL = url
    }

    public func detectLanguage(in audio: AudioSamples) async throws -> LanguageDetection {
        guard isLoaded else { throw SpeechEngineError.modelNotLoaded }
        return detection
    }

    public nonisolated func transcribe(_ audio: AudioSamples, options: TranscriptionOptions) -> AsyncThrowingStream<SegmentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let events = try await self.begin(options: options)
                    for event in events {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: SpeechEngineError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func begin(options: TranscriptionOptions) throws -> [SegmentEvent] {
        guard isLoaded else { throw SpeechEngineError.modelNotLoaded }
        transcribeCalls += 1
        lastOptions = options
        return script
    }
}
