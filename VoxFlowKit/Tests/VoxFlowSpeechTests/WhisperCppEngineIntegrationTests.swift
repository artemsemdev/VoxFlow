import Foundation
import Testing
import VoxFlowAudio
import VoxFlowCore
import VoxFlowDictation
import VoxFlowFiles
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
    @Test("file windows and dictation transcribe correctly through one loaded native model", .timeLimit(.minutes(1)))
    func sharedModelRoles() async throws {
        let fixture = Bundle.module.url(forResource: "attention-10s", withExtension: "wav", subdirectory: "Fixtures")!
        let audio = try AudioDecoder().decode(fixture)
        let engine = WhisperCppEngine()
        try await engine.load(modelAt: InstalledModel.url!)
        let (progress, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let files = FileTranscriber(decoder: RepeatedAudio(audio: audio), engine: engine.fileEngine, modelID: "fixture")
        let file = Task {
            defer { continuation.finish() }
            return try await files.transcribe(fixture, options: TranscriptionOptions(language: "en")) {
                if case .progress(let value) = $0, value > 0.05 && value < 1 { continuation.yield(()) }
            }
        }
        defer { file.cancel() }
        var iterator = progress.makeAsyncIterator()
        guard await iterator.next() != nil else {
            _ = try await file.value
            Issue.record("file completed without intermediate progress")
            return
        }
        let dictation = try await WindowedTranscriber(engine: engine).transcribe(AsyncStream { c in
            c.yield(AudioChunk(samples: audio.samples)); c.finish()
        }, options: TranscriptionOptions(language: "en")) { _ in }
        let document = try await file.value
        continuation.finish()
        var batch = ""
        for try await event in engine.transcribe(try RepeatedAudio(audio: audio).decode(fixture), options: TranscriptionOptions(language: "en")) {
            if case .segment(let segment) = event { batch += segment.text }
        }
        #expect(dictation.text.lowercased().contains("attention"))
        #expect(document.transcript.plainText.lowercased().contains("attention"))
        #expect(document.transcript.segments.map(\.start) == document.transcript.segments.map(\.start).sorted())
        #expect(abs(document.audioDuration - audio.duration * 3) < 1 / AudioSamples.sampleRate)
        #expect(document.transcript.plainText.lowercased().components(separatedBy: "attention").count - 1 == 3,
                "File: \(document.transcript.plainText); batch: \(batch); dictation: \(dictation.text)")
        #expect(Self.fixtureWords(document.transcript.plainText) == Self.fixtureWords(batch))
    }

    // The fixture pronounces "we're"/"we are" and "why"/"Y" alike; preserve every other word.
    private static func fixtureWords(_ text: String) -> [Substring] {
        text.lowercased().replacingOccurrences(of: "we're", with: "we are")
            .replacingOccurrences(of: "we’re", with: "we are").replacingOccurrences(of: " y fixed", with: " why fixed")
            .split { !$0.isLetter && !$0.isNumber }
    }

    private struct RepeatedAudio: AudioDecoding {
        let audio: AudioSamples
        func decode(_ url: URL) throws -> AudioSamples { AudioSamples(audio.samples + audio.samples + audio.samples) }
    }

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

    @Test("consumer cancellation after an event follows the documented stream contract")
    func cancellation() async throws {
        let fixture = Bundle.module.url(forResource: "attention-10s", withExtension: "wav", subdirectory: "Fixtures")!
        let audio = try AudioDecoder().decode(fixture)
        let engine = WhisperCppEngine()
        try await engine.load(modelAt: InstalledModel.url!)
        let task = Task {
            for try await _ in engine.transcribe(audio, options: TranscriptionOptions(language: "en")) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            // #125 / ADR-003: mid-run cancellation may end iteration silently. The consumer
            // must translate that outcome; this test does not measure native abort latency.
            if Task.isCancelled { throw SpeechEngineError.cancelled }
        }
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

@Suite("WhisperCppEngine cancellation without a model")
struct WhisperCppEngineCancellationTests {
    @Test("cancelling before transcribe throws without loading a model or starting native work")
    func cancelledBeforeStreamCreation() async {
        let engine = WhisperCppEngine()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            for try await _ in engine.transcribe(AudioSamples([]), options: TranscriptionOptions()) {}
        }
        await #expect(throws: SpeechEngineError.cancelled) { try await task.value }
    }
}
