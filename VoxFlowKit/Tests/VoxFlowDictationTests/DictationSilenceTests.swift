import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowDictation

@Suite("Dictation silence")
struct DictationSilenceTests {
    private func chunk(_ seconds: Double, level: Float = 0) -> AudioChunk {
        AudioChunk(samples: Array(repeating: level, count: Int(seconds * AudioSamples.sampleRate)))
    }

    private func feed(_ chunks: [AudioChunk]) -> AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            chunks.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    @Test("silent windows never reach language detection or decoding", arguments: [Float(0), 0.0002])
    func onlySilence(level: Float) async throws {
        // An unloaded engine throws if either detection or transcription is called.
        let engine = FakeSpeechEngine(script: [])
        let events = EventLog()
        let result = try await WindowedTranscriber(engine: engine).transcribe(
            feed([chunk(3, level: level), chunk(3, level: level), chunk(0.8, level: level)]),
            options: TranscriptionOptions()) { await events.append($0) }
        #expect(result.text.isEmpty)
        #expect(result.language == nil)
        #expect(abs(result.duration - 6.8) < 0.001)
        #expect(await engine.transcribeCalls == 0)
        #expect(await events.entries.isEmpty)
    }

    @Test("a quiet tail cannot append invented words or emit another live preview")
    func tailAfterSpeech() async throws {
        let phrase = "Привет. Скажи, пожалуйста, как там у вас дела?"
        let engine = FakeSpeechEngine(script: [.segment(TranscriptSegment(start: 0, end: 2.5, text: phrase)!)])
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let events = EventLog()
        let result = try await WindowedTranscriber(engine: engine).transcribe(
            feed([chunk(3, level: 0.1), chunk(0.5), chunk(2, level: 0.0002)]),
            options: TranscriptionOptions(language: "ru")) { await events.append($0) }
        #expect(result.text == phrase)
        #expect(result.rawText == phrase)
        #expect(result.segments.count == 1)
        #expect(await engine.transcribeCalls == 1)
        #expect(await events.entries == [.partialText(phrase)])
    }

    @Test("skipping initial silence keeps the spoken window's original timeline")
    func leadingSilence() async throws {
        let engine = FakeSpeechEngine(script: [.segment(TranscriptSegment(start: 0, end: 0.5, text: "hello")!)])
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let result = try await WindowedTranscriber(engine: engine).transcribe(
            feed([chunk(3), chunk(0.5, level: 0.03)]), options: TranscriptionOptions()) { _ in }
        #expect(result.text == "hello")
        #expect(result.segments.map(\.start) == [3])
        #expect(result.duration == 3.5)
        #expect(await engine.transcribeCalls == 1)
    }

    @Test("quiet brief speech survives even when the whole window RMS is below the floor")
    func quietSpeech() async throws {
        let engine = FakeSpeechEngine(script: [.segment(TranscriptSegment(start: 0, end: 1, text: "yes")!)])
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let samples = chunk(1).samples + chunk(0.2, level: 0.003).samples + chunk(1.8).samples
        let result = try await WindowedTranscriber(engine: engine).transcribe(
            feed([AudioChunk(samples: samples)]), options: TranscriptionOptions(language: "en")) { _ in }
        #expect(result.text == "yes")
        #expect(await engine.transcribeCalls == 1)
    }

    @Test("audible speech is not removed by a blacklist of subtitle phrases")
    func noTextBlacklist() async throws {
        let phrase = "Субтитры создавал DimaTorzok"
        let engine = FakeSpeechEngine(script: [.segment(TranscriptSegment(start: 0, end: 2, text: phrase)!)])
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let result = try await WindowedTranscriber(engine: engine).transcribe(
            feed([chunk(2, level: 0.03)]), options: TranscriptionOptions(language: "ru")) { _ in }
        #expect(result.text == phrase)
    }

    @Test("noise rejected by the speech detector cannot latch a language or emit text")
    func rejectedNoise() async throws {
        let engine = FakeSpeechEngine(script: [], detection: LanguageDetection(code: "en", confidence: 0.9))
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let events = EventLog()
        let result = try await WindowedTranscriber(engine: engine).transcribe(
            feed([chunk(3, level: 0.08)]), options: TranscriptionOptions()) { await events.append($0) }
        #expect(result.text.isEmpty)
        #expect(result.language == nil)
        #expect(await events.entries.isEmpty)
    }
}
