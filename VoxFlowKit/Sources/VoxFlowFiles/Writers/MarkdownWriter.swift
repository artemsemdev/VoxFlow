import VoxFlowCore

enum MarkdownWriter: TranscriptWriter {
    static let format = OutputFormat.md
    static func render(_ document: TranscriptDocument, timestamps: Bool) -> String {
        let header = "# \(document.baseName)\n\n_\(TimeCode.short(document.audioDuration)) · \(document.transcript.language ?? "auto") · \(document.modelID)_"
        let body = document.transcript.segments.map { segment in
            let text = TranscriptRenderer.cleanText(segment)
            return timestamps ? "**[\(TimeCode.short(segment.start))]** \(text)" : text
        }
        return ([header] + body).joined(separator: "\n\n") + "\n"
    }
}
