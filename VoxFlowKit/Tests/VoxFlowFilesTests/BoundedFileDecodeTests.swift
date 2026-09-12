import Foundation
import Synchronization
import Testing
import VoxFlowCore
@testable import VoxFlowFiles

@Suite("Bounded file decoding", .timeLimit(.minutes(1)))
struct BoundedFileDecodeTests {
    @Test("long files decode only the detection prefix and rolling window", arguments: [true, false])
    func boundedReadAhead(automatic: Bool) async throws {
        let source = Samples(count: 16_000 * 300)
        let engine = InspectingEngine(source: source)
        let transcriber = FileTranscriber(decoder: Decoder(source: source), engine: engine, modelID: "m")
        let document = try await transcriber.transcribe(URL(fileURLWithPath: "/tmp/long.wav"),
            options: TranscriptionOptions(language: automatic ? nil : "en")) { _ in }
        #expect(engine.snapshot.maxReadAhead <= (automatic ? 480_000 : 163_200))
        #expect(engine.snapshot.transcribedSamples == source.count)
        #expect(engine.snapshot.detectionSamples == (automatic ? 480_000 : 0))
        #expect(source.snapshot.largestRequest <= (automatic ? 480_000 : 163_200))
        #expect(document.audioDuration == 300)
    }

    @Test("duration and monotonic progress use actual EOF, not the estimated frame count", arguments: [1, 9_600_000])
    func inaccurateEstimate(estimate: Int) async throws {
        let source = Samples(count: 400_000, estimate: estimate)
        let engine = InspectingEngine(source: source)
        let transcriber = FileTranscriber(decoder: Decoder(source: source), engine: engine, modelID: "m")
        let progress = Progress()
        let document = try await transcriber.transcribe(URL(fileURLWithPath: "/tmp/long.wav"),
            options: TranscriptionOptions(language: "en")) { progress.append($0) }
        #expect(document.audioDuration == 25)
        #expect(document.transcript.segments.map(\.start) == [0, 10, 20])
        #expect(document.transcript.segments.map(\.end) == [10, 20, 25])
        #expect(progress.values == progress.values.sorted() && progress.values.last == 1)
        #expect(progress.values.dropLast().allSatisfy { $0 < 1 })
    }

    @Test("a late decoder error fails the file instead of returning a partial document")
    func lateReadFailure() async {
        let source = Samples(count: 480_000, failAfter: 170_000)
        let transcriber = FileTranscriber(decoder: Decoder(source: source),
                                          engine: InspectingEngine(source: source), modelID: "m")
        await #expect(throws: FileTranscriptionError.decodeFailed("late read")) {
            _ = try await transcriber.transcribe(URL(fileURLWithPath: "/tmp/long.wav"),
                options: TranscriptionOptions(language: "en")) { _ in }
        }
    }

    private struct Decoder: AudioDecoding {
        let source: Samples
        func decode(_ url: URL) throws -> AudioSamples { throw AudioDecodingError.decodeFailed("eager decode called") }
        func open(_ url: URL, progress: @escaping @Sendable (Double) -> Void) throws -> any AudioSampleReading {
            source
        }
    }

    private final class Samples: AudioSampleReading, Sendable {
        struct State { var offset = 0; var largestRequest = 0 }
        let count: Int
        let estimatedSampleCount: Int
        private let failAfter: Int?
        private let state = Mutex(State())
        var snapshot: State { state.withLock { $0 } }
        init(count: Int, estimate: Int? = nil, failAfter: Int? = nil) {
            self.count = count; estimatedSampleCount = estimate ?? count; self.failAfter = failAfter
        }
        func read(upTo sampleCount: Int) throws -> AudioSamples? {
            try state.withLock { state in
                if let failAfter, state.offset >= failAfter { throw AudioDecodingError.decodeFailed("late read") }
                guard state.offset < count else { return nil }
                state.largestRequest = max(state.largestRequest, sampleCount)
                let amount = min(sampleCount, count - state.offset)
                state.offset += amount
                return AudioSamples([Float](repeating: 0.1, count: amount))
            }
        }
    }

    private final class InspectingEngine: SpeechEngine, Sendable {
        struct State { var transcribedSamples = 0; var maxReadAhead = 0; var detectionSamples = 0 }
        let source: Samples
        private let state = Mutex(State())
        var snapshot: State { state.withLock { $0 } }
        init(source: Samples) { self.source = source }
        func load(modelAt url: URL) async throws {}
        func detectLanguage(in audio: AudioSamples) async throws -> LanguageDetection {
            state.withLock { $0.detectionSamples = audio.samples.count }
            return LanguageDetection(code: "en", confidence: 1)
        }
        func transcribe(_ audio: AudioSamples, options: TranscriptionOptions) -> AsyncThrowingStream<SegmentEvent, Error> {
            state.withLock { state in
                state.maxReadAhead = max(state.maxReadAhead, source.snapshot.offset - state.transcribedSamples)
                state.transcribedSamples += audio.samples.count
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(.progress(0.5))
                continuation.yield(.segment(TranscriptSegment(start: 0, end: audio.duration, text: "window")!))
                continuation.yield(.progress(1))
                continuation.finish()
            }
        }
    }
}
