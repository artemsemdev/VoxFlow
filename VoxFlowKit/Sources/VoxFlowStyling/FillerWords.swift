import Foundation
import VoxFlowCore

/// Filler-word/phrase list and removal (phase 4a plan, ruling 9).
public enum FillerWords: Sendable {
    public struct Result: Sendable, Equatable {
        public var text: String
        public var removed: Int
        public var removedFillerSpans: [RawTextSpan]?
    }

    /// Cleanup plus ranges into the unchanged input. The initial implementation is completed with
    /// the cleanup pipeline; keeping the seam here lets History persist observations, not guesses.
    public static func stripWithSpans(_ text: String) -> Result {
        var mapped = MappedText(text)
        _ = replace(&mapped, pattern: "\\s+", with: " ")
        _ = replace(&mapped, pattern: "^\\s+|\\s+$", with: "")

        var spans: [RawTextSpan]? = []
        var removed = 0
        let escapedWords = patterns.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        removed += replace(&mapped, pattern: "\\b(?:\(escapedWords))\\b", with: "", capture: 0, spans: &spans)
        removed += replace(&mapped, pattern: ",\\s*(like)\\s*,", with: ",", capture: 1, spans: &spans)
        removed += replace(&mapped, pattern: "(?:^\\s*|(?<=[.?!]\\s))(like)\\s*,\\s*", with: "",
                           capture: 1, spans: &spans)
        spans?.sort { $0.location < $1.location }
        return Result(text: collapseCleanup(mapped.text), removed: removed, removedFillerSpans: spans)
    }

    /// Whole-word/phrase filler markers matched case-insensitively anywhere in the text.
    /// `like` is handled separately by `strip` — it is only a filler when set off by commas
    /// or opening a clause followed by a comma, to avoid eating the verb "to like".
    public static let patterns: [String] = [
        "um", "uh", "erm", "hmm", "you know", "I mean", "sort of", "kind of",
    ]

    /// Strips filler words/phrases from `text`, then collapses the doubled spaces and
    /// dangling commas the removal can leave behind. Returns the cleaned text and how many
    /// filler occurrences were removed.
    public static func strip(_ text: String) -> (String, removed: Int) {
        var result = text
        var removed = 0

        let escapedWords = patterns.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        removed += replace(&result, pattern: "\\b(?:\(escapedWords))\\b", with: "")

        // "like" set off by commas: ", like," -> ",".
        removed += replace(&result, pattern: ",\\s*like\\s*,", with: ",")
        // M3: "like" opening a clause followed by a comma — either the very start of the text, or
        // right after a sentence-ending `.`/`?`/`!` and its following space (a new clause, not just
        // the string's start): "like, " -> "". Was anchored to `^`, so "It's late. Like, we should
        // go" never matched. The mid-text branch's lookbehind stops at the space rather than
        // consuming it, so the sentence boundary keeps its single space instead of colliding the
        // previous sentence into the next word.
        removed += replace(&result, pattern: "(?:^\\s*|(?<=[.?!]\\s))like\\s*,\\s*", with: "")

        result = collapseCleanup(result)
        return (result, removed)
    }

    private static func collapseCleanup(_ text: String) -> String {
        var result = text
        while result.contains(", ,") || result.contains(",  ,") {
            result = result.replacingOccurrences(of: ",  ,", with: ",")
            result = result.replacingOccurrences(of: ", ,", with: ",")
        }
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        if result.hasPrefix(", ") {
            result.removeFirst(2)
        } else if result.hasPrefix(",") {
            result.removeFirst(1)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    @discardableResult
    private static func replace(_ text: inout String, pattern: String, with replacement: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return 0
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else { return 0 }
        text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
        return matches.count
    }

    private struct MappedText {
        var text: String
        var originalOffsets: [Int]

        init(_ text: String) {
            self.text = text
            originalOffsets = Array(0..<text.utf16.count)
        }
    }

    @discardableResult
    private static func replace(_ mapped: inout MappedText, pattern: String, with replacement: String,
                                capture: Int? = nil, spans: inout [RawTextSpan]?) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
        let matches = regex.matches(in: mapped.text, range: NSRange(location: 0, length: mapped.originalOffsets.count))
        for match in matches.reversed() {
            if let capture, spans != nil {
                let range = match.range(at: capture)
                let offsets = mapped.originalOffsets[range.location..<(range.location + range.length)]
                if let first = offsets.min(), let last = offsets.max(),
                   let span = RawTextSpan(location: first, length: last - first + 1) {
                    spans!.append(span)
                } else {
                    spans = nil
                }
            }
            let range = match.range
            let sourceOffset = mapped.originalOffsets[range.location..<(range.location + range.length)].first ?? 0
            mapped.text = (mapped.text as NSString).replacingCharacters(in: range, with: replacement)
            mapped.originalOffsets.replaceSubrange(range.location..<(range.location + range.length),
                                                   with: repeatElement(sourceOffset, count: replacement.utf16.count))
        }
        return matches.count
    }

    private static func replace(_ mapped: inout MappedText, pattern: String, with replacement: String) -> Int {
        var ignored: [RawTextSpan]?
        return replace(&mapped, pattern: pattern, with: replacement, spans: &ignored)
    }
}
