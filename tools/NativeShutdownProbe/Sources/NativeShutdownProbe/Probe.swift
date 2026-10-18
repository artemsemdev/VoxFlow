import Foundation
import VoxFlowAudio
import VoxFlowCore
import VoxFlowLLM
import VoxFlowSpeech

/// A separate process is essential: in-process assertions cannot test GGML's exit destructors.
/// Keep both engines alive through exit, exactly as AppServices does; do not rely on ARC cleanup.
@main struct NativeShutdownProbe {
    static let speech = WhisperCppEngine()
    static let style = LlamaEngine()

    static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            fatalError("Usage: NativeShutdownProbe speech-model.bin style-model.gguf speech-fixture.wav")
        }
        let paths = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        try await speech.load(modelAt: paths[0])
        try await style.load(modelAt: paths[1])
        let audio = try AudioDecoder().decode(paths[2])
        _ = try await speech.detectLanguage(in: audio)
        for engine: any SpeechEngine in [speech, speech.fileEngine] {
            var text = ""
            for try await event in engine.transcribe(audio, options: TranscriptionOptions(language: "en")) {
                if case .segment(let segment) = event { text += segment.text }
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SpeechEngineError.transcriptionFailed(code: -1)
            }
        }
        _ = try await style.generate(ChatPrompt(system: "Reply briefly.", user: "Say hello."), maxNewTokens: 8)
        await speech.shutdown()
        await style.unload()
        print("Both native engines used and shut down; exiting with owners still retained.")
    }
}
