import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowFiles

struct FakeDecoder: AudioDecoding {
    var result: Result<AudioSamples, AudioDecodingError>
    func decode(_ url: URL) throws -> AudioSamples { try result.get() }
}

@Suite("FileTranscriber")
struct FileTranscriberTests {
    let url = URL(fileURLWithPath: "/tmp/interview-raw.m4a")

    @Test("decodes, auto-detects language, streams progress and builds the document")
    func happyPath() async throws {
        let engine = FakeSpeechEngine(script: [
            .progress(0.5),
            .segment(TranscriptSegment(start: 0, end: 2, text: "hello")!),
            .progress(1),
            .segment(TranscriptSegment(start: 2, end: 4, text: "world")!),
        ], detection: LanguageDetection(code: "de", confidence: 0.95))
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let decoder = FakeDecoder(result: .success(AudioSamples([Float](repeating: 0, count: 64_000))))   // 4 s
        let clock = TestClock(start: Date(timeIntervalSince1970: 100), step: 1.5)
        let transcriber = FileTranscriber(decoder: decoder, engine: engine, modelID: "whisper-small", now: clock.now)
        let progress = Progress()
        let document = try await transcriber.transcribe(url, options: TranscriptionOptions()) { progress.append($0) }
        #expect(document.transcript.language == "de")
        #expect(document.transcript.segments.map(\.text) == ["hello", "world"])
        #expect(document.audioDuration == 4)
        #expect(document.modelID == "whisper-small")
        #expect(document.sourceURL == url)
        #expect(await engine.lastOptions?.language == "de")   // detected language is passed to the engine
        let values = progress.values
        #expect(values.first == 0.05 && values.last == 1 && values == values.sorted())
    }

    @Test("explicit language skips detection")
    func explicitLanguage() async throws {
        let engine = FakeSpeechEngine(script: [])
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let transcriber = FileTranscriber(decoder: FakeDecoder(result: .success(AudioSamples([0]))), engine: engine, modelID: "m")
        let document = try await transcriber.transcribe(url, options: TranscriptionOptions(language: "en")) { _ in }
        #expect(document.transcript.language == "en")
    }

    @Test("decode errors map to FileTranscriptionError")
    func decodeErrors() async {
        let engine = FakeSpeechEngine(script: [])
        let transcriber = FileTranscriber(decoder: FakeDecoder(result: .failure(.decodeFailed("bad"))), engine: engine, modelID: "m")
        await #expect(throws: FileTranscriptionError.decodeFailed("bad")) { _ = try await transcriber.transcribe(url, options: TranscriptionOptions()) { _ in } }
        let unsupported = FileTranscriber(decoder: FakeDecoder(result: .failure(.unsupportedType("pages"))), engine: engine, modelID: "m")
        await #expect(throws: FileTranscriptionError.unsupportedType("pages")) { _ = try await unsupported.transcribe(url, options: TranscriptionOptions()) { _ in } }
    }

    @Test("engine not loaded surfaces as noModelInstalled")
    func noModel() async {
        let transcriber = FileTranscriber(decoder: FakeDecoder(result: .success(AudioSamples([0]))), engine: FakeSpeechEngine(script: []), modelID: "m")
        await #expect(throws: FileTranscriptionError.noModelInstalled) { _ = try await transcriber.transcribe(url, options: TranscriptionOptions(language: "en")) { _ in } }
    }
}

/// Thread-safe progress collector for tests.
final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}

/// Deterministic, lock-guarded clock for tests: each call returns the current time, then advances by `step`.
/// A genuinely `Sendable` replacement for a closure mutating a captured `var`, which Swift 6 rejects.
final class TestClock: Sendable {
    private let state: Mutex<Date>
    private let step: TimeInterval

    init(start: Date, step: TimeInterval) {
        state = Mutex(start)
        self.step = step
    }

    func now() -> Date {
        state.withLock { date in
            let current = date
            date.addTimeInterval(step)
            return current
        }
    }
}
