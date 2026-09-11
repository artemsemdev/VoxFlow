import Foundation
import Testing
import VoxFlowCore
@testable import VoxFlowFiles

@Suite("Transcript segment length")
struct TranscriptSegmenterTests {
    private func document(_ segments: [TranscriptSegment]) -> TranscriptDocument {
        TranscriptDocument(sourceURL: URL(fileURLWithPath: "/tmp/segmentation.wav"),
                           transcript: Transcript(segments: segments, language: "en"), modelID: "whisper",
                           audioDuration: 60, processingTime: 3, createdAt: Date(timeIntervalSince1970: 100))
    }

    @Test("sentences split inside a source cue and preserve metadata and source bounds")
    func sentences() throws {
        let source = document([try #require(TranscriptSegment(start: 10, end: 25, text: "Hello. Goodbye.", confidence: 0.8))])
        let output = TranscriptSegmenter.resegment(source, length: .sentences)
        #expect(output.transcript.segments.map(\.text) == ["Hello.", "Goodbye."])
        #expect(output.transcript.segments.map(\.start) == [10, 17])
        #expect(output.transcript.segments.map(\.end) == [16, 25])
        #expect(output.transcript.segments.map(\.confidence) == [0.8, 0.8])
        var restored = output
        restored.transcript.segments = source.transcript.segments
        #expect(restored == source)
    }

    @Test("Short targets 42 characters and Long 84 while preserving all words")
    func lengths() throws {
        let words = (1...30).map { "word\($0)" }.joined(separator: " ")
        let source = document([try #require(TranscriptSegment(start: 0, end: 30, text: words))])
        let short = TranscriptSegmenter.resegment(source, length: .short).transcript
        let long = TranscriptSegmenter.resegment(source, length: .long).transcript
        #expect(short.segments.count > long.segments.count)
        #expect(long.segments.count > 1)
        #expect(short.segments.allSatisfy { $0.text.count <= 42 })
        #expect(long.segments.allSatisfy { $0.text.count <= 84 })
        #expect(short.plainText == words)
        #expect(long.plainText == words)
        #expect(short.segments.first?.start == 0)
        #expect(short.segments.last?.end == 30)
        #expect(zip(short.segments, short.segments.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    @Test("unspaced Unicode tokens remain intact, including zero-duration cues")
    func unicode() throws {
        let text = String(repeating: "👩🏽‍💻e\u{301}", count: 50)
        let source = document([try #require(TranscriptSegment(start: 2, end: 2, text: text))])
        let output = TranscriptSegmenter.resegment(source, length: .short).transcript.segments
        #expect(output.count == 1)
        #expect(output.map(\.text).joined() == text)
        #expect(output.allSatisfy { $0.start == 2 && $0.end == 2 })
    }

    @Test("long URLs remain intact in exports and do not inflate the word count", arguments: [SegmentLength.short, .long])
    func longToken(length: SegmentLength) throws {
        let url = "https://example.invalid/" + String(repeating: "long-path", count: 20)
        let source = document([try #require(TranscriptSegment(start: 0, end: 20, text: url))])
        let output = TranscriptSegmenter.resegment(source, length: length)
        #expect(output.wordCount == 1)
        for format in OutputFormat.allCases {
            #expect(TranscriptRenderer.render(output, format: format, timestamps: false).contains(url))
        }
    }

    @Test("empty cues are ignored and original cue gaps are never filled by regrouping")
    func emptyAndGaps() throws {
        let source = document([
            try #require(TranscriptSegment(start: 0, end: 1, text: " \n ")),
            try #require(TranscriptSegment(start: 2, end: 3, text: "First")),
            try #require(TranscriptSegment(start: 20, end: 22, text: "Second")),
        ])
        let output = TranscriptSegmenter.resegment(source, length: .long).transcript.segments
        #expect(output.map(\.text) == ["First", "Second"])
        #expect(output.map(\.start) == [2, 20])
        #expect(output.map(\.end) == [3, 22])
        #expect(TranscriptSegmenter.resegment(document([]), length: .short).transcript.segments.isEmpty)
    }
}
