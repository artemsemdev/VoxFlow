import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowDictation

@Suite("WindowedTranscriber", .timeLimit(.minutes(1)))
struct WindowedTranscriberTests {
    func feed(_ chunks: [AudioChunk]) -> AsyncStream<AudioChunk> {
        AsyncStream { c in chunks.forEach { c.yield($0) }; c.finish() }
    }
    func voiced(_ seconds: Double) -> AudioChunk { AudioChunk(samples: Array(repeating: 0.3, count: Int(seconds * 16_000))) }
    func silent(_ seconds: Double) -> AudioChunk { AudioChunk(samples: Array(repeating: 0, count: Int(seconds * 16_000))) }

    @Test("two windows: segments are offset, the second window gets the first text as prompt context, language detected once")
    func twoWindows() async throws {
        let engine = FakeSpeechEngine(script: [.segment(TranscriptSegment(start: 0, end: 1, text: "hello world", confidence: 0.9)!)],
                                      detection: LanguageDetection(code: "en", confidence: 0.95))
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let transcriber = WindowedTranscriber(engine: engine)
        let events = EventLog()
        let result = try await transcriber.transcribe(feed([voiced(3), silent(0.5), voiced(3), silent(0.5)]),
                                                      options: TranscriptionOptions(vocabulary: ["VoxFlow"])) { await events.append($0) }
        #expect(result.text == "hello world hello world")
        #expect(result.rawText == result.text)
        #expect(result.segments.map(\.start) == [0, 3.5])
        #expect(result.language == LanguageDetection(code: "en", confidence: 0.95))
        #expect(result.wordCount == 4)
        #expect(result.lowConfidence == false)
        #expect(abs(result.duration - 7.0) < 0.001)
        #expect(await engine.transcribeCalls == 2)
        #expect(await engine.lastOptions == TranscriptionOptions(language: "en", vocabulary: ["VoxFlow"], promptContext: "hello world"))
        #expect(await events.entries == [.language(LanguageDetection(code: "en", confidence: 0.95)),
                                         .partialText("hello world"), .partialText("hello world hello world")])
    }

    @Test("short feed below 0.3 s produces an empty result without calling the engine")
    func tooShort() async throws {
        let engine = FakeSpeechEngine(script: [])
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let result = try await WindowedTranscriber(engine: engine).transcribe(feed([voiced(0.1)]), options: TranscriptionOptions()) { _ in }
        #expect(result.text.isEmpty && result.wordCount == 0)
        #expect(await engine.transcribeCalls == 0)
    }

    @Test("low confidence when the mean segment confidence is below 0.5")
    func lowConfidence() async throws {
        let engine = FakeSpeechEngine(script: [.segment(TranscriptSegment(start: 0, end: 1, text: "um", confidence: 0.2)!)])
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let result = try await WindowedTranscriber(engine: engine).transcribe(feed([voiced(1)]), options: TranscriptionOptions(language: "en")) { _ in }
        #expect(result.lowConfidence)
    }

    @Test("cancelling the consumer mid-run throws DictationError.cancelled (ruling on #125)")
    func cancellation() async throws {
        let engine = FakeSpeechEngine(script: [.segment(TranscriptSegment(start: 0, end: 1, text: "one", confidence: 0.9)!)])
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let started = Gate()
        let task = Task {
            try await WindowedTranscriber(engine: engine).transcribe(stream, options: TranscriptionOptions(language: "en")) { event in
                if case .partialText = event { await started.open() }
            }
        }
        continuation.yield(voiced(3)); continuation.yield(silent(0.5))   // first window completes → partial text
        await started.wait()
        task.cancel()
        continuation.finish()
        await #expect(throws: DictationError.cancelled) { _ = try await task.value }
    }

    @Test("engine failure surfaces as DictationError.engineFailed")
    func engineFailure() async throws {
        let engine = FakeSpeechEngine(script: [])   // never loaded → modelNotLoaded
        do {
            _ = try await WindowedTranscriber(engine: engine).transcribe(feed([voiced(1)]), options: TranscriptionOptions(language: "en")) { _ in }
            Issue.record("expected DictationError.engineFailed")
        } catch DictationError.engineFailed {
            // expected — matched on the case, not the payload (M8): the machine replaces the payload
            // with a fixed message anyway, so a test pinned to reflection output of the raw string is
            // both fragile and testing the wrong thing.
        } catch {
            Issue.record("expected .engineFailed, got \(error)")
        }
    }
}

actor EventLog {
    var entries: [DictationEvent] = []
    func append(_ e: DictationEvent) { entries.append(e) }
}

/// One-shot gate: `wait()` suspends until `open()` was called (returns at once afterwards).
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
