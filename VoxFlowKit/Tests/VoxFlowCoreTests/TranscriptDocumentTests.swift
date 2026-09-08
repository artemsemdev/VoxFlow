import Foundation
import Testing
@testable import VoxFlowCore

@Suite("TranscriptDocument")
struct TranscriptDocumentTests {
    @Test("derives base name, word count and duration from its parts")
    func derived() {
        let document = TranscriptDocument(
            sourceURL: URL(fileURLWithPath: "/tmp/lecture-04.wav"),
            transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 4.12, text: "Welcome back.")!], language: "en"),
            modelID: "whisper-large-v3-turbo", audioDuration: 5532, processingTime: 252, createdAt: Date(timeIntervalSince1970: 0))
        #expect(document.baseName == "lecture-04")
        #expect(document.wordCount == 2)
        #expect(document.transcript.language == "en")
    }
}
