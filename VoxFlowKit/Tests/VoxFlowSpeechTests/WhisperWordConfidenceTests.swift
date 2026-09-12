import Testing
import VoxFlowCore
@testable import VoxFlowSpeech

@Suite("Whisper word confidences")
struct WhisperWordConfidenceTests {
    @Test("groups split tokens into exact raw words and averages only their actual probabilities")
    func groupsTokens() throws {
        let text = " café finance!"
        let result = try #require(WhisperCppEngine.wordConfidences(
            tokenTexts: [" ca", "fé", " fin", "ance", "!"],
            probabilities: [0.8, 0.6, 0.9, 0.7, 0.8], segmentText: text))
        #expect(result.map(\.span) == [RawTextSpan(location: 1, length: 4)!, RawTextSpan(location: 6, length: 8)!])
        #expect(abs(result[0].confidence - 0.7) < 0.000_001)
        #expect(abs(result[1].confidence - 0.8) < 0.000_001)
    }

    @Test("does not invent spans when token text cannot reproduce the segment or probabilities are invalid")
    func rejectsUnalignableTokens() {
        #expect(WhisperCppEngine.wordConfidences(tokenTexts: [" wrong"], probabilities: [0.5], segmentText: " right") == nil)
        #expect(WhisperCppEngine.wordConfidences(tokenTexts: [" word"], probabilities: [.nan], segmentText: " word") == nil)
    }

    @Test("rejects canonically equal token text whose UTF-16 offsets differ from the segment")
    func rejectsDifferentCanonicalEncoding() {
        #expect(WhisperCppEngine.wordConfidences(
            tokenTexts: ["e\u{301}", " ", "x"], probabilities: [0.9, 0.1, 0.8], segmentText: "é x") == nil)
    }
}
