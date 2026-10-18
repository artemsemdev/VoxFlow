import Foundation
import VoxFlowCore

public enum SegmentLength: String, CaseIterable, Sendable {
    case sentences, short, long
    public var displayName: String { rawValue.capitalized }
    var characterLimit: Int? { switch self { case .sentences: nil; case .short: 42; case .long: 84 } }
}

/// Regroups text inside each source cue without running speech recognition again.
public enum TranscriptSegmenter {
    public static func resegment(_ document: TranscriptDocument, length: SegmentLength) -> TranscriptDocument {
        var output = document
        output.transcript.segments = document.transcript.segments.flatMap { split($0, length: length) }
        return output
    }

    private static func split(_ segment: TranscriptSegment, length: SegmentLength) -> [TranscriptSegment] {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        guard segment.start.isFinite, segment.end.isFinite else { return [segment] }
        var sentences: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { _, range, _, _ in
            sentences.append(range)
        }
        if sentences.isEmpty { sentences = [text.startIndex..<text.endIndex] }
        let ranges = sentences.flatMap { wrap(text, range: $0, limit: length.characterLimit) }
        let count = Double(text.count)
        // Character positions estimate internal timing; original source-cue boundaries stay fixed.
        var previousEnd = text.startIndex
        var consumed = 0
        return ranges.compactMap { range in
            consumed += text.distance(from: previousEnd, to: range.lowerBound)
            let start = segment.start + segment.duration * Double(consumed) / count
            consumed += text.distance(from: range.lowerBound, to: range.upperBound)
            previousEnd = range.upperBound
            let end = range.upperBound == text.endIndex ? segment.end : segment.start + segment.duration * Double(consumed) / count
            return TranscriptSegment(start: start, end: end, text: String(text[range]), confidence: segment.confidence)
        }
    }

    private static func wrap(_ text: String, range: Range<String.Index>, limit: Int?) -> [Range<String.Index>] {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, text[lower].isWhitespace { text.formIndex(after: &lower) }
        while lower < upper, text[text.index(before: upper)].isWhitespace { text.formIndex(before: &upper) }
        var output: [Range<String.Index>] = []
        while lower < upper {
            var end = limit.flatMap { text.index(lower, offsetBy: $0, limitedBy: upper) } ?? upper
            if end < upper, !text[end].isWhitespace {
                // Lengths are targets: never insert an export boundary inside a URL or word.
                end = text[lower..<end].lastIndex(where: \.isWhitespace)
                    ?? text[end..<upper].firstIndex(where: \.isWhitespace) ?? upper
            }
            var trimmedEnd = end
            while trimmedEnd > lower, text[text.index(before: trimmedEnd)].isWhitespace { text.formIndex(before: &trimmedEnd) }
            output.append(lower..<trimmedEnd)
            lower = end
            while lower < upper, text[lower].isWhitespace { text.formIndex(after: &lower) }
        }
        return output
    }
}
