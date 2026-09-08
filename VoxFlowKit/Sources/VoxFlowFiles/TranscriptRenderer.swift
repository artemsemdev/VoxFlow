import Foundation
import VoxFlowCore

protocol TranscriptWriter {
    static var format: OutputFormat { get }
    static func render(_ document: TranscriptDocument, timestamps: Bool) -> String
}

/// Renders a document in any output format; pure and deterministic (design 2f: export without re-processing).
public enum TranscriptRenderer {
    public static func render(_ document: TranscriptDocument, format: OutputFormat, timestamps: Bool) -> String {
        switch format {
        case .txt: TXTWriter.render(document, timestamps: timestamps)
        case .srt: SRTWriter.render(document, timestamps: timestamps)
        case .vtt: VTTWriter.render(document, timestamps: timestamps)
        case .json: JSONWriter.render(document, timestamps: timestamps)
        case .md: MarkdownWriter.render(document, timestamps: timestamps)
        }
    }

    static func cleanText(_ segment: TranscriptSegment) -> String {
        segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `cleanText`, with runs of `\n`/`\r\n` flattened to a single space — a blank line inside a
    /// cue's text would otherwise end the cue early in SRT/VTT.
    static func cueText(_ segment: TranscriptSegment) -> String {
        cleanText(segment).replacingOccurrences(of: "(\r\n|\n)+", with: " ", options: .regularExpression)
    }
}
