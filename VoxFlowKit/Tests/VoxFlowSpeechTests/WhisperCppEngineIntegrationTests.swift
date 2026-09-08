import Foundation
import Testing
import VoxFlowAudio
import VoxFlowCore
@testable import VoxFlowSpeech

/// Runs the real engine when a Whisper model is installed on this machine; skipped otherwise.
enum InstalledModel {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VoxFlow/Models")
    /// Smallest available first: tests care about the plumbing, not accuracy.
    static let url: URL? = ["ggml-small.bin", "ggml-large-v3-turbo.bin", "ggml-base.bin"]
        .map { directory.appendingPathComponent($0) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}

@Suite("WhisperCppEngine (RequiresModel)", .enabled(if: InstalledModel.url != nil,
       "No Whisper model in ~/Library/Application Support/VoxFlow/Models; download one via the app or the spike"))
struct WhisperCppEngineIntegrationTests {
    @Test("transcribes the fixture, streams ordered segments and detects English")
    func transcribesFixture() async throws {
        let fixture = Bundle.module.url(forResource: "attention-10s", withExtension: "wav", subdirectory: "Fixtures")!
        let audio = try AudioDecoder().decode(fixture)
        let engine = WhisperCppEngine()
        try await engine.load(modelAt: InstalledModel.url!)

        let language = try await engine.detectLanguage(in: audio)
        #expect(language.code == "en")
        #expect(language.confidence > 0.8)

        var segments: [TranscriptSegment] = []
        var lastProgress = 0.0
        for try await event in engine.transcribe(audio, options: TranscriptionOptions(language: "en")) {
            switch event {
            case .segment(let segment): segments.append(segment)
            case .progress(let value):
                #expect(value >= lastProgress)
                lastProgress = value
            }
        }
        let text = Transcript(segments: segments).plainText.lowercased()
        #expect(text.contains("attention"))
        #expect(segments.map(\.start) == segments.map(\.start).sorted())
        #expect(segments.last!.end <= audio.duration + 0.5)
        #expect(segments.allSatisfy { ($0.confidence ?? -1) >= 0 && ($0.confidence ?? 2) <= 1 })
    }

    @Test("cancelling the consumer aborts the run")
    func cancellation() async throws {
        let fixture = Bundle.module.url(forResource: "attention-10s", withExtension: "wav", subdirectory: "Fixtures")!
        let audio = try AudioDecoder().decode(fixture)
        let engine = WhisperCppEngine()
        try await engine.load(modelAt: InstalledModel.url!)
        let task = Task {
            for try await _ in engine.transcribe(audio, options: TranscriptionOptions(language: "en")) {}
        }
        // Cancel almost immediately; the engine must stop and throw `cancelled`.
        task.cancel()
        await #expect(throws: SpeechEngineError.cancelled) { try await task.value }
    }

    @Test("using the engine before load fails")
    func requiresLoad() async {
        let engine = WhisperCppEngine()
        await #expect(throws: SpeechEngineError.modelNotLoaded) {
            _ = try await engine.detectLanguage(in: AudioSamples([Float](repeating: 0, count: 16_000)))
        }
    }
}
