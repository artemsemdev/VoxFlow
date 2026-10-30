import AVFoundation
import Foundation
import Synchronization
import Testing
import VoxFlowAudio
import VoxFlowCore
import VoxFlowDictation
import VoxFlowFiles
import VoxFlowSpeech
import VoxFlowTestSupport

/// Explicit model selection keeps quality failures visible and prevents machine-dependent fallback.
@Suite("Transcription E2E (real model)", .serialized, .timeLimit(.minutes(3)),
       .enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_E2E_MODEL"] != nil,
                "Set VOXFLOW_E2E_MODEL to an absolute Whisper model path; see docs/testing/transcription-e2e.md"))
struct TranscriptionE2ETests {
    enum Scenario: String, CaseIterable, Sendable {
        case english, russian, autoEnglish, autoRussian, stereo48k, aac
        case longEnglish, longRussian, autoLongRussian
        case quiet, noisy, pauses, multipleWindows, autoMultipleWindows, continuousSpeech, silence, noiseOnly

        var language: String { [.russian, .autoRussian, .longRussian, .autoLongRussian].contains(self) ? "ru" : "en" }
        var isLong: Bool { [.longEnglish, .longRussian, .autoLongRussian].contains(self) }
        var fixtureName: String { "e2e-\(isLong ? "long-" : "")\(language)" }
        var automatic: Bool { self == .autoEnglish || self == .autoRussian || self == .autoMultipleWindows || self == .autoLongRussian }
        var repetitions: Int { self == .multipleWindows || self == .autoMultipleWindows || self == .continuousSpeech ? 6 : 1 }
        func reference() throws -> String {
            if isLong {
                let url = try #require(Bundle.module.url(forResource: fixtureName, withExtension: "txt", subdirectory: "Fixtures"))
                return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if self == .silence || self == .noiseOnly { return "" }
            let phrase = language == "ru"
                ? "Пожалуйста, отправь готовый отчёт завтра утром. Нам нужно проверить последние результаты перед началом встречи."
                : "Please send the updated report tomorrow morning. We need to review the final results before the meeting."
            return Array(repeating: phrase, count: repetitions).joined(separator: " ")
        }
        // Fixed acceptance budgets, chosen before measuring the models. Punctuation is ignored.
        var maximumWER: Double { self == .quiet || self == .noisy ? 0.25 : 0.15 }
    }

    @Test("audio → real recognition → transcript → exports; streamed dictation preserves words",
          arguments: Scenario.allCases)
    func transcribe(_ scenario: Scenario) async throws {
        try await withEngine { engine, model in
            let directory = TemporaryDirectory()
            let input = try makeInput(scenario, in: directory)
            let audio = try AudioDecoder().decode(input)
            #expect(audio.duration > 3, "A missing/empty speech fixture must never pass")
            if scenario.isLong { #expect(audio.duration > 30, "Long sentences must cross several recognition windows") }
            let options = TranscriptionOptions(language: scenario.automatic ? nil : scenario.language)
            let progress = Mutex<[Double]>([])
            let document = try await FileTranscriber(decoder: AudioDecoder(), engine: engine.fileEngine, modelID: model)
                .transcribe(input, options: options) { event in
                    if case .progress(let value) = event { progress.withLock { $0.append(value) } }
                }
            try checkWords(document.transcript.plainText, scenario: scenario, route: "file", model: model)
            checkTimeline(document.transcript.segments, duration: audio.duration)
            #expect(abs(document.audioDuration - audio.duration) < 0.05)
            #expect(document.transcript.language == scenario.language)
            let values = progress.withLock { $0 }
            #expect(values.last == 1)
            #expect(values.allSatisfy { (0...1).contains($0) })
            #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
            try checkExports(document, in: directory)

            // Full-context control isolates windowing from model/VAD quality on long sentences.
            if scenario.isLong {
                var batch: [TranscriptSegment] = []
                for try await event in engine.transcribe(audio, options: TranscriptionOptions(language: scenario.language)) {
                    if case .segment(let segment) = event { batch.append(segment) }
                }
                try checkWords(Transcript(segments: batch).plainText, scenario: scenario, route: "batch", model: model)
                checkTimeline(batch, duration: audio.duration)
            }
            let previews = Mutex<[String]>([])
            let result = try await WindowedTranscriber(engine: engine).transcribe(chunks(audio), options: options) { event in
                if case .partialText(let text) = event { previews.withLock { $0.append(text) } }
            }
            try checkWords(result.text, scenario: scenario, route: "dictation", model: model)
            checkTimeline(result.segments, duration: audio.duration)
            #expect(abs(result.duration - audio.duration) < 0.05)
            #expect(result.rawText == result.text)
            if scenario.automatic { #expect(result.language?.code == scenario.language) }
            let emitted = previews.withLock { $0 }
            if try scenario.reference().isEmpty {
                #expect(emitted.isEmpty, "Silence/noise must not emit a text preview")
            } else {
                #expect(emitted.last == result.text)
                #expect(zip(emitted, emitted.dropFirst()).allSatisfy { $1.hasPrefix($0) })
            }
        }
    }

    @Test("cancel a multi-window file, reject corrupt input, then reuse the same real model")
    func cancellationAndRecovery() async throws {
        try await withEngine { engine, model in
            let directory = TemporaryDirectory()
            let input = try makeInput(.multipleWindows, in: directory)
            let transcriber = FileTranscriber(decoder: AudioDecoder(), engine: engine.fileEngine, modelID: model)
            let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let task = Task {
                defer { continuation.finish() }
                return try await transcriber.transcribe(input, options: TranscriptionOptions(language: "en")) { event in
                    if case .progress(let value) = event, value > 0.05 && value < 1 { continuation.yield(()) }
                }
            }
            defer { task.cancel() }
            var iterator = events.makeAsyncIterator()
            let started: Void? = await iterator.next()
            #expect(started != nil, "Must cancel after recognition starts, not before decoding")
            task.cancel()
            await #expect(throws: FileTranscriptionError.cancelled) { _ = try await task.value }
            let corrupt = directory.file("corrupt.wav")
            try Data("not an audio file".utf8).write(to: corrupt)
            do {
                _ = try await transcriber.transcribe(corrupt, options: TranscriptionOptions()) { _ in }
                Issue.record("Corrupt audio unexpectedly succeeded")
            } catch FileTranscriptionError.decodeFailed { /* Expected typed failure. */ }
            let valid = try makeInput(.english, in: directory)
            let recovered = try await transcriber.transcribe(valid, options: TranscriptionOptions(language: "en")) { _ in }
            try checkWords(recovered.transcript.plainText, scenario: .english, route: "recovery", model: model)
        }
    }

    private func withEngine(_ body: (WhisperCppEngine, String) async throws -> Void) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VOXFLOW_E2E_MODEL"])
        let model = URL(fileURLWithPath: path)
        let engine = WhisperCppEngine()
        do {
            try await engine.load(modelAt: model)
            try await body(engine, model.lastPathComponent)
        } catch {
            await engine.unload()
            throw error
        }
        await engine.unload()
    }

    private func makeInput(_ scenario: Scenario, in directory: TemporaryDirectory) throws -> URL {
        let fixture = try #require(Bundle.module.url(forResource: scenario.fixtureName, withExtension: "wav", subdirectory: "Fixtures"))
        var samples = try AudioDecoder().decode(fixture).samples
        let silence = [Float](repeating: 0, count: 16_000)
        switch scenario {
        case .multipleWindows, .autoMultipleWindows: samples = (0..<scenario.repetitions).flatMap { _ in samples + silence }
        case .continuousSpeech: samples = (0..<scenario.repetitions).flatMap { _ in samples }
        case .pauses: samples = silence + silence + samples + silence + silence + silence
        case .quiet: samples = samples.map { $0 * 0.08 }
        case .noisy: samples = zip(samples, noise(samples.count)).map { $0 + $1 * 0.02 }
        case .silence: samples = Array(repeating: 0, count: 96_000)
        case .noiseOnly: samples = noise(96_000).map { $0 * 0.08 }
        default: break
        }
        let url = directory.file("\(scenario.rawValue).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        // Close the file before the real streaming decoder opens it.
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        guard scenario == .stereo48k || scenario == .aac else { return url }
        let converted = directory.file(scenario == .aac ? "converted.m4a" : "converted.wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = scenario == .aac
            ? ["-f", "m4af", "-d", "aac@44100", "-b", "96000", url.path, converted.path]
            : ["-f", "WAVE", "-d", "LEI16@48000", "-c", "2", url.path, converted.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "Audio format conversion failed")
        return converted
    }

    private func noise(_ count: Int) -> [Float] {
        var seed: UInt32 = 42
        return (0..<count).map { _ in
            seed = 1_664_525 &* seed &+ 1_013_904_223
            return Float(seed >> 8) / Float(0x00ff_ffff) * 2 - 1
        }
    }

    private func chunks(_ audio: AudioSamples) -> AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            for offset in stride(from: 0, to: audio.samples.count, by: 1600) {
                continuation.yield(AudioChunk(samples: Array(audio.samples[offset..<min(offset + 1600, audio.samples.count)])))
            }
            continuation.finish()
        }
    }

    private func checkWords(_ text: String, scenario: Scenario, route: String, model: String) throws {
        let reference = try scenario.reference()
        let wer = WordErrorRate.measure(reference: reference, hypothesis: text)
        if scenario.isLong {
            let anchors = scenario.language == "ru"
                ? ["не дал", "заново перечитывать", "если обнаружишь", "не удаляй", "не заменяй", "остальных проектах"]
                : ["did not work", "entire conversation", "if you notice", "do not delete", "original measurements", "wider release"]
            let normalized = WordErrorRate.words(text).joined(separator: " ")
            #expect(anchors.allSatisfy { normalized.contains($0) }, "\(route) lost a clause or negation: \(text)")
        }
        // Machine-readable observations remain in the test log even for a failing acceptance check.
        let record: [String: Any] = ["model": model, "scenario": scenario.rawValue, "route": route,
                                     "wer": wer, "reference": reference, "actual": text]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            print("TRANSCRIPTION_E2E " + String(decoding: data, as: UTF8.self))
        }
        if try scenario.reference().isEmpty {
            #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(route) invented text: \(text)")
        } else {
            #expect(wer <= scenario.maximumWER, "\(scenario.rawValue)/\(route) WER=\(wer); actual: \(text)")
        }
    }

    private func checkTimeline(_ segments: [TranscriptSegment], duration: Double) {
        #expect(segments.map(\.start) == segments.map(\.start).sorted())
        #expect(segments.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.end <= duration + 0.5 },
                "Audio duration: \(duration); segment ranges: \(segments.map { "\($0.start)...\($0.end)" })")
        #expect(segments.allSatisfy { $0.confidence.map { (0...1).contains($0) } ?? false })
    }

    private func checkExports(_ document: TranscriptDocument, in directory: TemporaryDirectory) throws {
        let exporter = TranscriptExporter(directory: directory.file("exports"))
        let urls = try exporter.exportAll(document, formats: OutputFormat.allCases, timestamps: false)
        for format in OutputFormat.allCases {
            let url = try #require(urls[format])
            let text = try String(contentsOf: url, encoding: .utf8)
            for segment in document.transcript.segments {
                // JSON uses escaping; decode it below instead of matching serialized strings.
                if format != .json { #expect(text.contains(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))) }
            }
            if format == .txt {
                #expect(WordErrorRate.words(text) == WordErrorRate.words(document.transcript.plainText))
                let duplicate = try exporter.export(document, format: format, timestamps: false)
                #expect(duplicate != url)
                #expect(try String(contentsOf: url, encoding: .utf8) == text)
            }
            if format == .srt || format == .vtt {
                #expect(text.components(separatedBy: " --> ").count - 1 == document.transcript.segments.count)
                if format == .vtt { #expect(text.hasPrefix("WEBVTT")) }
            }
            if format == .json {
                let decoded = try JSONDecoder().decode(ExportedTranscript.self, from: Data(text.utf8))
                #expect(decoded.language == document.transcript.language)
                #expect(decoded.model == document.modelID)
                #expect(decoded.duration == document.audioDuration)
                #expect(decoded.segments.map(\.text) == document.transcript.segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) })
                #expect(decoded.segments.map(\.start) == document.transcript.segments.map(\.start))
                #expect(decoded.segments.map(\.end) == document.transcript.segments.map(\.end))
            }
        }
    }

    private struct ExportedTranscript: Decodable {
        struct Segment: Decodable { let text: String; let start, end: Double }
        let language: String?, model: String, duration: Double, segments: [Segment]
    }
}

/// Levenshtein word distance counts substitutions, deletions AND hallucinated insertions.
private enum WordErrorRate {
    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func measure(reference: String, hypothesis: String) -> Double {
        let expected = words(reference), actual = words(hypothesis)
        var row = Array(0...actual.count)
        for (i, word) in expected.enumerated() {
            var next = [i + 1]
            for (j, candidate) in actual.enumerated() {
                next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (word == candidate ? 0 : 1)))
            }
            row = next
        }
        return Double(row[actual.count]) / Double(max(expected.count, 1))
    }
}

@Suite("Transcription quality metric")
struct WordErrorRateTests {
    @Test func countsErrors() {
        #expect(WordErrorRate.measure(reference: "one two three", hypothesis: "one three") == 1.0 / 3)
        #expect(WordErrorRate.measure(reference: "one two", hypothesis: "one red") == 0.5)
        #expect(WordErrorRate.measure(reference: "one two", hypothesis: "one two two") == 0.5)
        #expect(WordErrorRate.measure(reference: "", hypothesis: "invented words") == 2)
        #expect(WordErrorRate.measure(reference: "", hypothesis: "") == 0)
        #expect(WordErrorRate.measure(reference: "Отчёт готов!", hypothesis: "отчет готов") == 0)
    }
}
