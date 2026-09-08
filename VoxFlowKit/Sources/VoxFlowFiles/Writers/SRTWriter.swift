import VoxFlowCore

enum SRTWriter: TranscriptWriter {
    static let format = OutputFormat.srt
    static func render(_ document: TranscriptDocument, timestamps: Bool) -> String {
        document.transcript.segments.enumerated().map { index, segment in
            "\(index + 1)\n\(TimeCode.srt(segment.start)) --> \(TimeCode.srt(segment.end))\n\(TranscriptRenderer.cueText(segment))"
        }.joined(separator: "\n\n") + "\n"
    }
}
