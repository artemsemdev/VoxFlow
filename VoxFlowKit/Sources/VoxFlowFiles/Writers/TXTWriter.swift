import VoxFlowCore

enum TXTWriter: TranscriptWriter {
    static let format = OutputFormat.txt
    static func render(_ document: TranscriptDocument, timestamps: Bool) -> String {
        document.transcript.segments.map { segment in
            let text = TranscriptRenderer.cleanText(segment)
            return timestamps ? "[\(TimeCode.bracket(segment.start)) → \(TimeCode.bracket(segment.end))] \(text)" : text
        }.joined(separator: "\n") + "\n"
    }
}
