import Foundation

/// Filler-word/phrase list and removal (phase 4a plan, ruling 9).
public enum FillerWords: Sendable {
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
        // "like" opening a clause at the start of the text: "like, " -> "".
        removed += replace(&result, pattern: "^\\s*like\\s*,\\s*", with: "")

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
}
