import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowFiles
@testable import VoxFlowSpeech

@Suite("Files and dictation scheduling", .timeLimit(.minutes(1)))
struct FileDictationSchedulingTests {
    @Test("dictation finishes within the processing budget while a ten-minute fake file remains running", arguments: [false, true])
    func dictationDuringFile(automaticLanguage: Bool) async throws {
        let native = SimulatedNativeWork()
        let file = FileTranscriber(decoder: TenMinuteDecoder(), engine: Lane(native: native, priority: .file), modelID: "m")
        let job = Task {
            let document = try await file.transcribe(URL(fileURLWithPath: "/tmp/long.wav"),
                                                     options: TranscriptionOptions(language: automaticLanguage ? nil : "en")) { _ in }
            native.continuation.yield("file done")
            return document
        }
        defer { job.cancel(); native.firstWindow.signal(); native.remainingWindows.signal(); native.continuation.finish() }
        var events = native.events.makeAsyncIterator()
        #expect(await events.next() == "file started")
        let started = native.elapsed
        let dictation = Task {
            let chunks = AsyncStream<AudioChunk> { c in c.yield(AudioChunk(samples: [Float](repeating: 0, count: 16_000))); c.finish() }
            return try await WindowedTranscriber(engine: Lane(native: native, priority: .dictation))
                .transcribe(chunks, options: TranscriptionOptions(language: automaticLanguage ? nil : "en")) { _ in }
        }
        defer { dictation.cancel() }
        #expect(await events.next() == "dictation queued")
        native.firstWindow.signal()
        if automaticLanguage {
            // Detection and inference are separate requests. A file window can start between them;
            // release it only once dictation inference has actually queued, without wall-clock sleeps.
            while let event = await events.next() { if event == "dictation queued" { break } }
            native.remainingWindows.signal()
        }
        let result = try await dictation.value
        #expect(result.text == "dictated words")
        #expect(native.dictationFinishedAt - started < FlowBarConfig().processingTimeout)
        #expect(native.fileWindowsAtDictationFinish < 60)
        if !automaticLanguage {
            #expect(await events.next() == "second file window")
            native.remainingWindows.signal()
        }
        let document = try await job.value
        #expect(document.audioDuration == 600 && document.transcript.segments.count == 60)
        native.continuation.finish()
    }

    private struct TenMinuteDecoder: AudioDecoding {
        func decode(_ url: URL) throws -> AudioSamples { AudioSamples([Float](repeating: 0, count: 600 * 16_000)) }
    }

    /// Fake native inference uses the production work queue but touches no hardware.
    /// At 10x real time, the old single 600-second call costs 60 simulated seconds.
    private final class SimulatedNativeWork: Sendable {
        struct State { var elapsed = 0.0; var files = 0; var dictationFinishedAt = Double.infinity; var filesAtDictationFinish = 60 }
        let queue = WhisperWorkQueue()
        let firstWindow = DispatchSemaphore(value: 0)
        let remainingWindows = DispatchSemaphore(value: 0)
        let events: AsyncStream<String>
        let continuation: AsyncStream<String>.Continuation
        private let state = Mutex(State())
        var elapsed: Double { state.withLock { $0.elapsed } }
        var dictationFinishedAt: Double { state.withLock { $0.dictationFinishedAt } }
        var fileWindowsAtDictationFinish: Int { state.withLock { $0.filesAtDictationFinish } }

        init() { (events, continuation) = AsyncStream.makeStream() }

        func detect(priority: WhisperWorkQueue.Priority) async -> LanguageDetection {
            await withCheckedContinuation { result in
                queue.enqueue(priority: priority) {
                    self.state.withLock { $0.elapsed += 0.75 }
                    result.resume(returning: LanguageDetection(code: "en", confidence: 1))
                }
                if priority == .dictation { continuation.yield("dictation queued") }
            }
        }

        func process(_ audio: AudioSamples, priority: WhisperWorkQueue.Priority,
                     output: AsyncThrowingStream<SegmentEvent, Error>.Continuation) {
            queue.enqueue(priority: priority) {
                if priority == .file {
                    let index = self.state.withLock { $0.files += 1; return $0.files }
                    if index == 1 { self.continuation.yield("file started"); self.firstWindow.wait() }
                    if index == 2 { self.continuation.yield("second file window"); self.remainingWindows.wait() }
                }
                self.state.withLock {
                    $0.elapsed += audio.duration / 10
                    if priority == .dictation { $0.dictationFinishedAt = $0.elapsed; $0.filesAtDictationFinish = $0.files }
                }
                output.yield(.segment(TranscriptSegment(start: 0, end: audio.duration,
                                                        text: priority == .file ? "file words" : "dictated words")!))
                output.finish()
            }
            if priority == .dictation { continuation.yield("dictation queued") }
        }
    }

    private struct Lane: SpeechEngine {
        let native: SimulatedNativeWork
        let priority: WhisperWorkQueue.Priority
        func load(modelAt url: URL) async throws {}
        func detectLanguage(in audio: AudioSamples) async throws -> LanguageDetection { await native.detect(priority: priority) }
        func transcribe(_ audio: AudioSamples, options: TranscriptionOptions) -> AsyncThrowingStream<SegmentEvent, Error> {
            AsyncThrowingStream { native.process(audio, priority: priority, output: $0) }
        }
    }
}
