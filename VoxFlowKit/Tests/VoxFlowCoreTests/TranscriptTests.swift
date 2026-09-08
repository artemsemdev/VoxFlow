import Foundation
import Testing
@testable import VoxFlowCore

@Suite("Transcript")
struct TranscriptTests {
    @Test("segment duration is end minus start")
    func segmentDuration() {
        let segment = TranscriptSegment(start: 1.5, end: 4.25, text: "hello")
        #expect(segment?.duration == 2.75)
    }

    @Test("segment rejects end before start")
    func segmentOrdering() {
        #expect(TranscriptSegment(start: 2, end: 1, text: "x") == nil)
    }

    @Test("transcript duration is the end of the last segment; empty is zero")
    func transcriptDuration() {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0, end: 4.12, text: "Welcome back.")!,
            TranscriptSegment(start: 4.12, end: 9.86, text: "Last week we covered attention.")!,
        ])
        #expect(transcript.duration == 9.86)
        #expect(Transcript(segments: []).duration == 0)
    }

    @Test("word count and plain text")
    func wordCountAndPlainText() {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0, end: 1, text: " Welcome back. ")!,
            TranscriptSegment(start: 1, end: 2, text: "Today we're  picking up")!,
        ])
        #expect(transcript.wordCount == 6)
        #expect(transcript.plainText == "Welcome back. Today we're  picking up")
    }

    @Test("confidence is optional and round-trips through Codable")
    func confidenceCodable() throws {
        let segment = TranscriptSegment(start: 0, end: 1, text: "hi", confidence: 0.87)!
        let data = try JSONEncoder().encode(segment)
        #expect(try JSONDecoder().decode(TranscriptSegment.self, from: data) == segment)
        #expect(TranscriptSegment(start: 0, end: 1, text: "x")!.confidence == nil)
    }
}
