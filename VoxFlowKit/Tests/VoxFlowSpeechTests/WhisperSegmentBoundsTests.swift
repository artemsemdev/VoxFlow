import Foundation
import Testing
import VoxFlowCore
@testable import VoxFlowSpeech

@Suite("Whisper segment bounds")
struct WhisperSegmentBoundsTests {
    @Test("clips padded native times while preserving text and confidence spans")
    func paddedTimes() throws {
        let words = [WordConfidence(span: RawTextSpan(location: 0, length: 4)!, confidence: 0.8)!]
        let segment = TranscriptSegment(start: -0.1, end: 29.98, text: "word", confidence: 0.9, wordConfidences: words)!
        let bounded = try #require(WhisperCppEngine.boundedSegment(segment, duration: 6))
        #expect(bounded.start == 0 && bounded.end == 6)
        #expect(bounded.text == segment.text)
        #expect(bounded.confidence == segment.confidence)
        #expect(bounded.wordConfidences == words)
        #expect(WhisperCppEngine.boundedSegment(bounded, duration: 6) == bounded)
    }

    @Test("drops segments outside the recording instead of creating zero-length subtitle cues")
    func outsideAudio() {
        for (start, end) in [(6.0, 30.0), (10, 30), (-2, -1), (1, 1), (0, Double.infinity)] {
            let segment = TranscriptSegment(start: start, end: end, text: "outside")!
            #expect(WhisperCppEngine.boundedSegment(segment, duration: 6) == nil)
        }
        let segment = TranscriptSegment(start: 0, end: 1, text: "word")!
        #expect(WhisperCppEngine.boundedSegment(segment, duration: 0) == nil)
        #expect(WhisperCppEngine.boundedSegment(segment, duration: .nan) == nil)
    }
}
