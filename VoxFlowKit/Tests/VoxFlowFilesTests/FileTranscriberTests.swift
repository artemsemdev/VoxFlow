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

    @Test("long files yield the engine between bounded windows and preserve absolute timestamps")
    func boundedWindows() async throws {
        let samples = (0..<400_000).map { Float($0 % 100) / 100 }
        let engine = WindowRecordingEngine()
        let transcriber = FileTranscriber(decoder: FakeDecoder(result: .success(AudioSamples(samples))), engine: engine, modelID: "m")
        let progress = Progress()
        let document = try await transcriber.transcribe(url, options: TranscriptionOptions()) { progress.append($0) }
        #expect(engine.calls.map { $0.audio.duration } == [10, 10, 5])
        #expect(engine.calls.flatMap { $0.audio.samples } == samples)
        #expect(engine.detectionDurations == [25])
        #expect(document.transcript.segments.map(\.start) == [0, 10, 20])
        #expect(document.transcript.segments.map(\.end) == [10, 20, 25])
        #expect(engine.calls.allSatisfy { $0.options.promptContext == nil })
        #expect(document.audioDuration == 25 && document.modelID == "m" && document.sourceURL == url)
        #expect(progress.values == progress.values.sorted() && progress.values.last == 1)
    }

    @Test("tails below 200ms stay with the previous window, including Whisper's mel-frame rounding boundary",
          arguments: [1, 1599, 1600, 1799, 3199, 3200])
    func tinyTail(samples tail: Int) async throws {
        let engine = WindowRecordingEngine()
        let samples = [Float](repeating: 0, count: 320_000 + tail)
        let transcriber = FileTranscriber(decoder: FakeDecoder(result: .success(AudioSamples(samples))), engine: engine, modelID: "m")
        _ = try await transcriber.transcribe(url, options: TranscriptionOptions(language: "en")) { _ in }
        let expected = tail < 3200 ? [160_000, 160_000 + tail] : [160_000, 160_000, tail]
        #expect(engine.calls.map { $0.audio.samples.count } == expected)
    }

    @Test("auto detection retains Whisper's first thirty seconds independently of transcription windows")
    func detectionWindow() async throws {
        let engine = WindowRecordingEngine()
        let transcriber = FileTranscriber(decoder: FakeDecoder(result: .success(AudioSamples([Float](repeating: 0, count: 45 * 16_000)))),
                                          engine: engine, modelID: "m")
        _ = try await transcriber.transcribe(url, options: TranscriptionOptions()) { _ in }
        #expect(engine.detectionDurations == [30])
        #expect(engine.calls.allSatisfy { $0.options.language == "en" })
    }

    @Test("a quiet boundary is preferred to cutting through speech at ten seconds")
    func quietBoundary() async throws {
        var samples = [Float](repeating: 0.1, count: 400_000)
        samples.replaceSubrange(128_000..<134_400, with: repeatElement(Float(0), count: 6400))
        let engine = WindowRecordingEngine()
        let transcriber = FileTranscriber(decoder: FakeDecoder(result: .success(AudioSamples(samples))), engine: engine, modelID: "m")
        _ = try await transcriber.transcribe(url, options: TranscriptionOptions(language: "en")) { _ in }
        #expect(engine.calls.map { $0.audio.samples.count } == [134_400, 160_000, 105_600])
        #expect(engine.calls.flatMap { $0.audio.samples } == samples)
    }

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

private final class WindowRecordingEngine: SpeechEngine, Sendable {
    struct Call: Sendable { let audio: AudioSamples; let options: TranscriptionOptions }
    private let recorded = Mutex<[Call]>([])
    private let detections = Mutex<[Double]>([])
    var calls: [Call] { recorded.withLock { $0 } }
    var detectionDurations: [Double] { detections.withLock { $0 } }
    func load(modelAt url: URL) async throws {}
    func detectLanguage(in audio: AudioSamples) async throws -> LanguageDetection {
        detections.withLock { $0.append(audio.duration) }
        return LanguageDetection(code: "en", confidence: 1)
    }
    func transcribe(_ audio: AudioSamples, options: TranscriptionOptions) -> AsyncThrowingStream<SegmentEvent, Error> {
        recorded.withLock { $0.append(Call(audio: audio, options: options)) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.progress(0.5))
            continuation.yield(.segment(TranscriptSegment(start: 0, end: audio.duration, text: "window")!))
            continuation.yield(.progress(1))
            continuation.finish()
        }
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
