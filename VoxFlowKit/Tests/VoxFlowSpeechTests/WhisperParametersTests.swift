import Testing
import VoxFlowCore
@testable import VoxFlowSpeech

@Suite("WhisperParameters")
struct WhisperParametersTests {
    @Test("auto language maps to nil language and no forced detection")
    func autoLanguage() {
        let params = WhisperParameters(options: TranscriptionOptions(), availableCores: 10)
        #expect(params.language == nil)
        #expect(params.threadCount == 8)     // min(cores, 8): Metal does the heavy lifting
    }

    @Test("explicit language and thread count are passed through; threads clamp to 1...16")
    func explicit() {
        let params = WhisperParameters(options: TranscriptionOptions(language: "de", threadCount: 99), availableCores: 4)
        #expect(params.language == "de")
        #expect(params.threadCount == 16)
        #expect(WhisperParameters(options: TranscriptionOptions(threadCount: 0), availableCores: 4).threadCount == 1)
    }

    @Test("vocabulary becomes the initial prompt and the no-speech threshold is forwarded")
    func promptAndThreshold() {
        let options = TranscriptionOptions(vocabulary: ["VoxFlow", "Kubernetes"], noSpeechThreshold: 0.4)
        let params = WhisperParameters(options: options, availableCores: 8)
        #expect(params.initialPrompt == "VoxFlow, Kubernetes")
        #expect(params.noSpeechThreshold == 0.4)
    }
}
