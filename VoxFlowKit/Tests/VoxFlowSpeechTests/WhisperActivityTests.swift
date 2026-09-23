import Foundation
import Testing
import VoxFlowAudio
import VoxFlowCore
@testable import VoxFlowSpeech

@Suite("Whisper speech activity (RequiresModel)", .serialized,
       .enabled(if: InstalledModel.url != nil, "No installed Whisper model"))
struct WhisperActivityTests {
    @Test("silence and deterministic background noise produce no dictated text")
    func noSpeech() async throws {
        let engine = WhisperCppEngine()
        try await engine.load(modelAt: InstalledModel.url!)
        var seed: UInt32 = 42
        let noise: [Float] = (0..<96_000).map { _ in
            seed = 1_664_525 &* seed &+ 1_013_904_223
            return (Float(seed >> 8) / Float(0x00ff_ffff) - 0.5) * 0.16
        }
        for samples in [[Float](repeating: 0, count: 48_000), noise] {
            var text = ""
            var progress = 0.0
            for try await event in engine.transcribe(AudioSamples(samples), options: TranscriptionOptions(language: "ru", promptContext: "Привет. Как дела?")) {
                switch event {
                case .segment(let segment): text += segment.text
                case .progress(let value): progress = value
                }
            }
            #expect(text.isEmpty)
            #expect(progress == 1)
        }
        await engine.unload()
    }

    @Test("speech survives detector trimming with timestamps on the original audio timeline")
    func speechWithSilence() async throws {
        let fixture = Bundle.module.url(forResource: "attention-10s", withExtension: "wav", subdirectory: "Fixtures")!
        let spoken = try AudioDecoder().decode(fixture)
        let padded = AudioSamples([Float](repeating: 0, count: 32_000) + spoken.samples + [Float](repeating: 0, count: 48_000))
        let engine = WhisperCppEngine()
        try await engine.load(modelAt: InstalledModel.url!)
        var segments: [TranscriptSegment] = []
        for try await event in engine.transcribe(padded, options: TranscriptionOptions(language: "en")) {
            if case .segment(let segment) = event { segments.append(segment) }
        }
        let text = Transcript(segments: segments).plainText.lowercased()
        #expect(text.contains("attention"))
        #expect(text.components(separatedBy: "attention").count - 1 == 1)
        #expect(segments.first.map { $0.start >= 1.5 } == true)
        #expect(segments.last.map { $0.end <= padded.duration } == true)
        await engine.unload()
    }

    // External public regression audio stays outside the repository; see docs/validation/dictation-silence.
    @Test("public DimaTorzok noise regression is rejected by the installed turbo model",
          .enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_NOISE_REGRESSION_AUDIO"] != nil))
    func reportedNoise() async throws {
        let path = ProcessInfo.processInfo.environment["VOXFLOW_NOISE_REGRESSION_AUDIO"]!
        let audio = try AudioDecoder().decode(URL(fileURLWithPath: path))
        let engine = WhisperCppEngine()
        try await engine.load(modelAt: InstalledModel.directory.appendingPathComponent("ggml-large-v3-turbo.bin"))
        var segments: [TranscriptSegment] = []
        for try await event in engine.transcribe(audio, options: TranscriptionOptions(language: "ru")) {
            if case .segment(let segment) = event { segments.append(segment) }
        }
        #expect(segments.isEmpty, "Background noise must not become subtitle credits")
        await engine.unload()
    }
}
