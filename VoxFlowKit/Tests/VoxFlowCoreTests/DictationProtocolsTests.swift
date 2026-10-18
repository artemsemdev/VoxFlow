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
    }

    @Test("I2: promptContext comes first, then vocabulary — so continuation survives truncation")
    func promptContextBeforeVocabulary() {
        #expect(TranscriptionOptions(vocabulary: ["VoxFlow"], promptContext: "so we said").initialPrompt == "so we said\nVoxFlow")
    }

    @Test("I2: promptContext is truncated to its last 200 characters")
    func promptContextTruncatedToLast200Characters() {
        let long = String(repeating: "a", count: 50) + String(repeating: "b", count: 250)
        let prompt = TranscriptionOptions(promptContext: long).initialPrompt
        #expect(prompt?.count == 200)
        #expect(prompt == String(repeating: "b", count: 200))
    }

    @Test("I2: vocabulary is appended in order while the section stays <= 400 characters, dropping the word that would exceed it")
    func vocabularyCappedAt400Characters() {
        // Each word is 18 characters; with the ", " separator, every word after the first adds 20 —
        // 20 words land exactly at 398, a 21st would push it to 418 and is dropped.
        let words = (0..<25).map { String(format: "word-%013d", $0) }
        let prompt = TranscriptionOptions(vocabulary: words).initialPrompt!
        #expect(prompt.count <= 400)
        #expect(prompt.hasPrefix("\(words[0]), \(words[1])"))
        #expect(prompt.contains(words[19]))
        #expect(!prompt.contains(words[20]))
    }

    @Test("I2: a long promptContext plus a full vocabulary both survive, context first")
    func promptContextAndVocabularyBothCapped() {
        let longContext = String(repeating: "c", count: 300)
        let words = (0..<25).map { String(format: "word-%013d", $0) }
        let prompt = TranscriptionOptions(vocabulary: words, promptContext: longContext).initialPrompt!
        let lines = prompt.split(separator: "\n", maxSplits: 1).map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].count == 200)
        #expect(lines[0] == String(repeating: "c", count: 200))
        #expect(lines[1].count <= 400)
        #expect(lines[1].hasPrefix(words[0]))
    }

    @Test("I2: empty vocabulary with a prompt context, and a nil/empty promptContext with vocabulary")
    func promptEmptyCases() {
        #expect(TranscriptionOptions(vocabulary: [], promptContext: "so we said").initialPrompt == "so we said")
        #expect(TranscriptionOptions(vocabulary: ["VoxFlow"], promptContext: nil).initialPrompt == "VoxFlow")
        #expect(TranscriptionOptions(vocabulary: ["VoxFlow"], promptContext: "").initialPrompt == "VoxFlow")
        #expect(TranscriptionOptions(vocabulary: [], promptContext: "").initialPrompt == nil)
        #expect(TranscriptionOptions(vocabulary: [], promptContext: nil).initialPrompt == nil)
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
