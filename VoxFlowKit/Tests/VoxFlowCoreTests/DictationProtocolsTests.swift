import Foundation
import Testing
@testable import VoxFlowCore

@Suite("Dictation protocols")
struct DictationProtocolsTests {
    @Test("AudioChunk computes RMS and duration at 16 kHz")
    func chunk() {
        let chunk = AudioChunk(samples: [0.5, -0.5, 0.5, -0.5])
        #expect(abs(chunk.rms - 0.5) < 1e-6)
        #expect(chunk.duration == 4.0 / 16_000)
        #expect(AudioChunk(samples: []).rms == 0)
    }

    @Test("initial prompt joins vocabulary and prompt context; nil when both empty")
    func prompt() {
        #expect(TranscriptionOptions().initialPrompt == nil)
        #expect(TranscriptionOptions(vocabulary: ["VoxFlow", "GRDB"]).initialPrompt == "VoxFlow, GRDB")
        #expect(TranscriptionOptions(promptContext: "so we said").initialPrompt == "so we said")
        #expect(TranscriptionOptions(vocabulary: ["VoxFlow"], promptContext: "so we said").initialPrompt == "VoxFlow\nso we said")
    }

    @Test("SystemMonotonicClock never goes backwards and sleeps at least the requested time")
    func systemClock() async throws {
        let clock = SystemMonotonicClock()
        let a = clock.now()
        try await clock.sleep(for: 0.01)
        let b = clock.now()
        #expect(b - a >= 0.01)
    }
}
