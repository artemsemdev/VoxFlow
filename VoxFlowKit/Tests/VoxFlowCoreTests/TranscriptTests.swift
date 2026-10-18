import Foundation
import Testing
@testable import VoxFlowCore

@Suite("Transcript")
struct TranscriptTests {
    @Test("raw annotations validate UTF-16 ranges and use the design's strict 80% word threshold")
    func rawAnnotations() throws {
        let raw = "🙂 finance"
        let span = try #require(RawTextSpan(location: 3, length: 7))
        let low = try #require(WordConfidence(span: span, confidence: 0.78))
        let boundary = try #require(WordConfidence(span: span, confidence: 0.80))
        #expect(String(raw[try #require(span.range(in: raw))]) == "finance")
        #expect(low.isLowConfidence)
        #expect(!boundary.isLowConfidence)
        #expect(DictationAnnotations(wordConfidences: [low]).validated(for: raw) != nil)
        let outside = try #require(RawTextSpan(location: 50, length: 1))
        #expect(DictationAnnotations(removedFillerSpans: [outside]).validated(for: raw) == nil)
    }

    @Test("decoded or mutated invalid, zero, overflowing, duplicate and overlapping spans are safely rejected")
    func rejectsMalformedAnnotations() throws {
        let decoder = JSONDecoder()
        for json in [
            #"{"location":-1,"length":1}"#,
            #"{"location":0,"length":0}"#,
            #"{"location":9223372036854775807,"length":2}"#,
        ] {
            let span = try decoder.decode(RawTextSpan.self, from: Data(json.utf8))
            #expect(span.range(in: "word") == nil)
            #expect(DictationAnnotations(removedFillerSpans: [span]).validated(for: "word") == nil)
        }

        let whole = RawTextSpan(location: 0, length: 4)!
        let tail = RawTextSpan(location: 2, length: 2)!
        #expect(DictationAnnotations(removedFillerSpans: [whole, whole]).validated(for: "word") == nil)
        #expect(DictationAnnotations(removedFillerSpans: [whole, tail]).validated(for: "word") == nil)
        #expect(DictationAnnotations(removedFillerSpans: [whole, whole]).fillersRemoved == nil)
        let zero = try decoder.decode(RawTextSpan.self, from: Data(#"{"location":0,"length":0}"#.utf8))
        #expect(DictationAnnotations(removedFillerSpans: [zero]).fillersRemoved == nil)
    }

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
