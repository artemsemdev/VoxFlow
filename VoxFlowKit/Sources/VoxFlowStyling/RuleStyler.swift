import Foundation
import VoxFlowCore

/// Deterministic, rule-based `TextStyler` (phase 4a plan, ruling 1). Phase 5 replaces the
/// style step with an LLM-backed styler behind the same `TextStyler` protocol; fillers and
/// auto-punctuation stay rule-based global toggles either way.
///
/// Pipeline: normalise whitespace → (removeFillers) strip fillers → (autoPunctuate) sentence
/// capitalisation + terminal period + standalone `i` → `I` + space after `,.?!` → style.
/// `verbatim` short-circuits the whole pipeline and returns `raw` unchanged.
public struct RuleStyler: TextStyler, Sendable {
    /// Contraction table (case-insensitive match, initial capital preserved on the expansion).
    private static let contractions: [(String, String)] = [
        ("can't", "cannot"),
        ("won't", "will not"),
        ("don't", "do not"),
        ("i'm", "i am"),
        ("it's", "it is"),
        ("we're", "we are"),
        ("you're", "you are"),
        ("that's", "that is"),
        ("let's", "let us"),
        ("gonna", "going to"),
        ("wanna", "want to"),
    ]

    public init() {}

    public func style(_ raw: String, options: StylingOptions) -> StyledText {
        guard options.style != .verbatim else {
            return StyledText(text: raw, fillersRemoved: 0, cursorOffset: nil)
        }

        var text = Self.collapseWhitespace(raw)
        var fillersRemoved = 0

        if options.removeFillers {
            let (stripped, removed) = FillerWords.strip(text)
            text = stripped
            fillersRemoved = removed
        }

        if options.autoPunctuate {
            text = Self.autoPunctuate(text)
        }

        switch options.style {
        case .formal:
            text = Self.applyFormal(text)
        case .casual:
            break
        case .veryCasual:
            text = text.lowercased()
            if text.hasSuffix(".") {
                text.removeLast()
            }
        case .verbatim:
            break // unreachable: handled by the early return above.
        }

        return StyledText(text: text, fillersRemoved: fillersRemoved, cursorOffset: nil)
    }

    // MARK: - Auto-punctuate

    private static func autoPunctuate(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        result = insertSpaceAfterPunctuation(result)
        result = capitalizeStandaloneI(result)
        result = capitalizeSentences(result)
        if let last = result.last, !".?!".contains(last) {
            result += "."
        }
        return collapseWhitespace(result)
    }

    private static func insertSpaceAfterPunctuation(_ text: String) -> String {
        replacing(text, pattern: "([,.?!])([A-Za-z])", template: "$1 $2")
    }

    private static func capitalizeStandaloneI(_ text: String) -> String {
        replacing(text, pattern: "\\bi\\b", template: "I")
    }

    private static func capitalizeSentences(_ text: String) -> String {
        // Built as a String (not `[Character]`) because `Character.uppercased()` can yield more
        // than one grapheme cluster (e.g. German "ß" -> "SS"); `Character(_:)` traps on that.
        var result = ""
        result.reserveCapacity(text.count)
        var shouldCapitalize = true
        for c in text {
            if shouldCapitalize, c.isLetter {
                result += c.uppercased()
                shouldCapitalize = false
            } else {
                result.append(c)
                if c == "." || c == "?" || c == "!" {
                    shouldCapitalize = true
                } else if !c.isWhitespace {
                    shouldCapitalize = false
                }
            }
        }
        return result
    }

    // MARK: - Formal

    private static func applyFormal(_ text: String) -> String {
        var result = text
        for (contraction, expansion) in contractions {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: contraction))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let nsRange = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: nsRange).reversed()
            for match in matches {
                guard let range = Range(match.range, in: result) else { continue }
                let matched = String(result[range])
                var replacement = expansion
                if let first = matched.first, first.isUppercase {
                    replacement = replacement.prefix(1).uppercased() + replacement.dropFirst()
                }
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    // MARK: - Whitespace

    private static func collapseWhitespace(_ text: String) -> String {
        let collapsed = replacing(text, pattern: "\\s+", template: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
