import Foundation
import Testing
@testable import VoxFlowCore

@Suite("Speech types")
struct SpeechTypesTests {
    @Test("audio duration derives from the fixed 16 kHz rate")
    func audioDuration() {
        let audio = AudioSamples([Float](repeating: 0, count: 32_000))
        #expect(audio.duration == 2)
        #expect(AudioSamples.sampleRate == 16_000)
    }

    @Test("language detection below 0.6 is low confidence (chip shows EN?)")
    func lowConfidence() {
        #expect(LanguageDetection(code: "en", confidence: 0.59).isLowConfidence)
        #expect(LanguageDetection(code: "en", confidence: 0.6).isLowConfidence == false)
    }

    @Test("vocabulary becomes the initial prompt, comma separated; empty is nil")
    func initialPrompt() {
        var options = TranscriptionOptions()
        #expect(options.initialPrompt == nil)
        options.vocabulary = ["VoxFlow", "Kubernetes", "Priya Raghunathan"]
        #expect(options.initialPrompt == "VoxFlow, Kubernetes, Priya Raghunathan")
    }

    @Test("defaults: auto language, no vocabulary, engine-chosen threads, no-speech 0.6")
    func defaults() {
        let options = TranscriptionOptions()
        #expect(options.language == nil)
        #expect(options.vocabulary.isEmpty)
        #expect(options.threadCount == nil)
        #expect(options.noSpeechThreshold == 0.6)
    }

    @Test("model descriptor exposes the on-disk file name from its download URL")
    func descriptorFileName() {
        let model = ModelDescriptor(
            id: "whisper-small", displayName: "Whisper small", role: .speech,
            downloadURL: URL(string: "https://example.com/models/ggml-small.bin")!,
            sizeInBytes: 487_601_967, sha256: "1be3", languagesSummary: "99 languages", isDefault: false)
        #expect(model.fileName == "ggml-small.bin")
    }
}
