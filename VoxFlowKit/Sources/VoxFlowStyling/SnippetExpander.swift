import Foundation

/// A user-defined text snippet (phase 4a plan, ruling 4). `trigger` includes the leading
/// `/` (e.g. `"/sig"`); `onlyInBundleID` restricts expansion to one app.
public struct SnippetRule: Sendable, Equatable {
    public var trigger: String
    public var body: String
    public var onlyInBundleID: String?

    public init(trigger: String, body: String, onlyInBundleID: String? = nil) {
        self.trigger = trigger
        self.body = body
        self.onlyInBundleID = onlyInBundleID
    }
}

/// Expands snippet triggers inside already-styled text (ruling 4). Matches `/sig` or its
/// spoken form `slash sig` (case-insensitive, whole word); with `sayPrefix` the trigger must
/// additionally be preceded by the spoken word "snippet" (which is consumed too). A rule whose
/// `onlyInBundleID` does not match `context.bundleID` is skipped — its trigger text is left as
/// typed. Body placeholders `cursor`, `date`, `clipboard`, `app` are whole-word, case-insensitive.
public struct SnippetExpander: Sendable {
    public let snippets: [SnippetRule]
    public let sayPrefix: Bool
    public let context: (date: Date, clipboard: String?, appName: String?, bundleID: String?)

    public init(
        snippets: [SnippetRule],
        sayPrefix: Bool,
        context: (date: Date, clipboard: String?, appName: String?, bundleID: String?)
    ) {
        self.snippets = snippets
        self.sayPrefix = sayPrefix
        self.context = context
    }

    public func expand(_ text: String) -> (text: String, cursorOffset: Int?, used: [String]) {
        let applicable = snippets.filter { rule in
            guard let only = rule.onlyInBundleID else { return true }
            return only == context.bundleID
        }
        guard !applicable.isEmpty else {
            return (text, nil, [])
        }

        var matches: [(range: Range<String.Index>, rule: SnippetRule)] = []
        for rule in applicable {
            guard let pattern = triggerPattern(for: rule) else { continue }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, options: [], range: nsRange) {
                guard let range = Range(match.range, in: text) else { continue }
                matches.append((range, rule))
            }
        }
        guard !matches.isEmpty else {
            return (text, nil, [])
        }
        matches.sort { $0.range.lowerBound < $1.range.lowerBound }

        var accepted: [(range: Range<String.Index>, rule: SnippetRule)] = []
        var lastEnd = text.startIndex
        for match in matches where match.range.lowerBound >= lastEnd {
            accepted.append(match)
            lastEnd = match.range.upperBound
        }

        var result = ""
        var used: [String] = []
        var cursorOffset: Int?
        var cursor = text.startIndex
        for match in accepted {
            result += text[cursor..<match.range.lowerBound]
            let (expanded, localCursor) = expandBody(match.rule.body)
            if let localCursor, cursorOffset == nil {
                cursorOffset = result.count + localCursor
            }
            result += expanded
            used.append(match.rule.trigger)
            cursor = match.range.upperBound
        }
        result += text[cursor...]

        return (result, cursorOffset, used)
    }

    // MARK: - Matching

    private func triggerPattern(for rule: SnippetRule) -> String? {
        let noSlash = rule.trigger.hasPrefix("/") ? String(rule.trigger.dropFirst()) : rule.trigger
        guard !noSlash.isEmpty else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: noSlash)

        if sayPrefix {
            return "\\bsnippet\\s+(?:/\(escaped)\\b|slash\\s+\(escaped)\\b)"
        }
        return "(?:(?<![A-Za-z0-9_])/\(escaped)\\b|\\bslash\\s+\(escaped)\\b)"
    }

    // MARK: - Body placeholders

    /// Cursor markers are split out before expanding user-provided placeholder values. This keeps
    /// attachment characters or the word "cursor" in clipboard/app text from becoming markers.
    /// Only runs of spaces directly touching a removed marker are normalized; all other authored
    /// and clipboard whitespace is preserved verbatim.
    private func expandBody(_ body: String) -> (text: String, cursorOffset: Int?) {
        let cursorRanges = wordRanges(body, "cursor", includingBraces: true)
        guard !cursorRanges.isEmpty else {
            return (expandPlaceholders(in: body), nil)
        }

        var fragments: [String] = []
        var start = body.startIndex
        for range in cursorRanges {
            fragments.append(String(body[start..<range.lowerBound]))
            start = range.upperBound
        }
        fragments.append(String(body[start...]))

        for index in fragments.indices {
            if index > 0 { fragments[index] = collapsingLeadingSpaces(in: fragments[index]) }
            if index < cursorRanges.count { fragments[index] = collapsingTrailingSpaces(in: fragments[index]) }
        }
        // The first marker owns the reported caret gap. Each later marker is only removed, so when
        // it has a space on both sides those sides become one space rather than adding another gap.
        for index in fragments.indices.dropFirst(2) where fragments[index - 1].last == " " && fragments[index].first == " " {
            fragments[index].removeFirst()
        }
        let expanded = fragments.map(expandPlaceholders)
        return (expanded.joined(), expanded[0].count)
    }

    private func expandPlaceholders(in body: String) -> String {
        var result = replaceAllOccurrences(of: "date", with: formattedDate(), in: body)
        result = replaceAllOccurrences(of: "clipboard", with: context.clipboard ?? "", in: result)
        return replaceAllOccurrences(of: "app", with: context.appName ?? "", in: result)
    }

    private func collapsingLeadingSpaces(in text: String) -> String {
        var start = text.startIndex
        while start < text.endIndex, text[start] == " " { text.formIndex(after: &start) }
        return start == text.startIndex ? text : " " + String(text[start...])
    }

    private func collapsingTrailingSpaces(in text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous] == " " else { break }
            end = previous
        }
        return end == text.endIndex ? text : String(text[..<end]) + " "
    }

    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: context.date)
    }

    /// Replaces every whole-word, case-insensitive occurrence of `word` in `text` with `value`.
    private func replaceAllOccurrences(of word: String, with value: String, in text: String) -> String {
        var result = text
        for range in wordRanges(result, word).reversed() {
            result.replaceSubrange(range, with: value)
        }
        return result
    }

    /// All whole-word, case-insensitive ranges of `word` in `text`, in left-to-right order.
    private func wordRanges(_ text: String, _ word: String, includingBraces: Bool = false) -> [Range<String.Index>] {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let pattern = includingBraces ? "\\{\(escaped)\\}|\\b\(escaped)\\b" : "\\b\(escaped)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: nsRange).compactMap { Range($0.range, in: text) }
    }
}
