import Foundation
import Testing
import VoxFlowCore
@testable import VoxFlowFiles

@Suite("TranscriptRenderer")
struct TranscriptRendererTests {
    static let document = TranscriptDocument(
        sourceURL: URL(fileURLWithPath: "/Users/anh/Recordings/lecture-04.wav"),
        transcript: Transcript(segments: [
            TranscriptSegment(start: 0, end: 4.12, text: " Welcome back. Today we're picking up where we left off.", confidence: 0.91)!,
            TranscriptSegment(start: 4.12, end: 9.86, text: " Last week we covered why fixed-length context vectors become a bottleneck.")!,
        ], language: "en"),
        modelID: "whisper-large-v3-turbo", audioDuration: 9.86, processingTime: 0.62,
        createdAt: Date(timeIntervalSince1970: 1_757_289_600))   // 2025-09-08T00:00:00Z

    @Test("TXT with timestamps")
    func txtTimestamps() {
        #expect(TranscriptRenderer.render(Self.document, format: .txt, timestamps: true) == """
        [00:00:00.000 → 00:00:04.120] Welcome back. Today we're picking up where we left off.
        [00:00:04.120 → 00:00:09.860] Last week we covered why fixed-length context vectors become a bottleneck.

        """)
    }

    @Test("TXT without timestamps")
    func txtPlain() {
        #expect(TranscriptRenderer.render(Self.document, format: .txt, timestamps: false) == """
        Welcome back. Today we're picking up where we left off.
        Last week we covered why fixed-length context vectors become a bottleneck.

        """)
    }

    @Test("SRT")
    func srt() {
        #expect(TranscriptRenderer.render(Self.document, format: .srt, timestamps: false) == """
        1
        00:00:00,000 --> 00:00:04,120
        Welcome back. Today we're picking up where we left off.

        2
        00:00:04,120 --> 00:00:09,860
        Last week we covered why fixed-length context vectors become a bottleneck.

        """)
    }

    @Test("SRT flattens internal newlines in a segment to a single space")
    func srtFlattensNewlines() {
        let document = TranscriptDocument(
            sourceURL: Self.document.sourceURL,
            transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "line one\n\nline two")!], language: "en"),
            modelID: Self.document.modelID, audioDuration: 1, processingTime: 0, createdAt: Self.document.createdAt)
        #expect(TranscriptRenderer.render(document, format: .srt, timestamps: false) == """
        1
        00:00:00,000 --> 00:00:01,000
        line one line two

        """)
    }

    @Test("VTT")
    func vtt() {
        #expect(TranscriptRenderer.render(Self.document, format: .vtt, timestamps: true) == """
        WEBVTT

        00:00:00.000 --> 00:00:04.120
        Welcome back. Today we're picking up where we left off.

        00:00:04.120 --> 00:00:09.860
        Last week we covered why fixed-length context vectors become a bottleneck.

        """)
    }

    @Test("VTT flattens internal newlines in a segment to a single space")
    func vttFlattensNewlines() {
        let document = TranscriptDocument(
            sourceURL: Self.document.sourceURL,
            transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "line one\n\nline two")!], language: "en"),
            modelID: Self.document.modelID, audioDuration: 1, processingTime: 0, createdAt: Self.document.createdAt)
        #expect(TranscriptRenderer.render(document, format: .vtt, timestamps: false) == """
        WEBVTT

        00:00:00.000 --> 00:00:01.000
        line one line two

        """)
    }

    @Test("Markdown with and without timestamps")
    func markdown() {
        #expect(TranscriptRenderer.render(Self.document, format: .md, timestamps: true) == """
        # lecture-04

        _0:10 · en · whisper-large-v3-turbo_

        **[0:00]** Welcome back. Today we're picking up where we left off.

        **[0:04]** Last week we covered why fixed-length context vectors become a bottleneck.

        """)
        #expect(TranscriptRenderer.render(Self.document, format: .md, timestamps: false).contains("\n\nWelcome back."))
    }

    @Test("JSON is stable, sorted, ISO-8601, includes confidence only when present")
    func json() throws {
        let text = TranscriptRenderer.render(Self.document, format: .json, timestamps: true)
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        #expect(object["source"] as? String == "lecture-04.wav")
        #expect(object["language"] as? String == "en")
        #expect(object["model"] as? String == "whisper-large-v3-turbo")
        #expect(object["createdAt"] as? String == "2025-09-08T00:00:00Z")
        #expect(object["words"] as? Int == 21)
        let segments = object["segments"] as! [[String: Any]]
        #expect(segments.count == 2)
        #expect(segments[0]["confidence"] as? Double == 0.91)
        #expect(segments[1]["confidence"] == nil)
        #expect(segments[0]["text"] as? String == "Welcome back. Today we're picking up where we left off.")
        #expect(text.hasSuffix("\n"))
        #expect(TranscriptRenderer.render(Self.document, format: .json, timestamps: true) == text)   // deterministic
    }
}
