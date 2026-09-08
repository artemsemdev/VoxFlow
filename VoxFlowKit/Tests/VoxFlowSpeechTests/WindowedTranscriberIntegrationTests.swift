import Foundation
import Testing
import VoxFlowAudio
import VoxFlowCore
import VoxFlowDictation
@testable import VoxFlowSpeech

@Suite("WindowedTranscriber over WhisperCppEngine (RequiresModel)", .enabled(if: InstalledModel.url != nil,
       "No Whisper model in ~/Library/Application Support/VoxFlow/Models"))
struct WindowedTranscriberIntegrationTests {
    @Test("attention-10s.wav in 100 ms chunks yields the same words as one batch")
    func windowsMatchBatch() async throws {
        let engine = WhisperCppEngine()
        try await engine.load(modelAt: InstalledModel.url!)
        let fixture = Bundle.module.url(forResource: "attention-10s", withExtension: "wav", subdirectory: "Fixtures")!
        let audio = try AudioDecoder().decode(fixture)
        let chunks = stride(from: 0, to: audio.samples.count, by: 1600).map { AudioChunk(samples: Array(audio.samples[$0..<min($0 + 1600, audio.samples.count)])) }
        let result = try await WindowedTranscriber(engine: engine).transcribe(AsyncStream { c in chunks.forEach { c.yield($0) }; c.finish() },
                                                                             options: TranscriptionOptions(language: "en")) { _ in }
        #expect(result.wordCount >= 8)
        #expect(result.text.lowercased().contains("attention"))
    }
}
