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

    /// M1: the offset used to be measured *before* the trailing `"  " -> " "` collapse ran, so a
    /// double space anywhere earlier in the body (pre-existing, or left behind by removing the
    /// `cursor` word itself) silently shifted the reported position by one per collapse. A sentinel
    /// (`\u{FFFC}`, the Unicode "object replacement character" — never typed by a user) stands in
    /// for the first `cursor` occurrence through the collapse, so the offset is read back from the
    /// *final* string instead of a pre-collapse one.
    private func expandBody(_ body: String) -> (text: String, cursorOffset: Int?) {
        var result = replaceAllOccurrences(of: "date", with: formattedDate(), in: body)
        result = replaceAllOccurrences(of: "clipboard", with: context.clipboard ?? "", in: result)
        result = replaceAllOccurrences(of: "app", with: context.appName ?? "", in: result)

        let cursorRanges = wordRanges(result, "cursor", includingBraces: true)
        guard let first = cursorRanges.first else {
            return (collapseSpaces(result), nil)
        }
        let sentinel = "\u{FFFC}"
        for range in cursorRanges.reversed() {
            result.replaceSubrange(range, with: range == first ? sentinel : "")
        }
        result = collapseSpaces(result)
        guard let sentinelRange = result.range(of: sentinel) else {
            return (result, nil)
        }
        let cursorOffset = result.distance(from: result.startIndex, to: sentinelRange.lowerBound)
        result.removeSubrange(sentinelRange)
        return (result, cursorOffset)
    }

    private func collapseSpaces(_ text: String) -> String {
        var result = text
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result
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
