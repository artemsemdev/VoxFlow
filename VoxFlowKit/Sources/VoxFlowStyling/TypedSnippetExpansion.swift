import Foundation

/// A replacement in an Accessibility text field. Both range and caret use UTF-16 offsets.
public struct TypedSnippetExpansion: Sendable, Equatable {
    public let range: NSRange
    public let text: String
    public let caretUTF16: Int
    public let trigger: String
}

extension SnippetExpander {
    /// Matches the complete token immediately before an unselected caret, optionally followed by
    /// a space. A short trigger sharing a prefix with a longer one waits for that space. The spoken
    /// "snippet" prefix does not apply to keyboard input, which already requires the literal slash.
    public func expandTyped(in text: String, selection: NSRange) -> TypedSnippetExpansion? {
        guard selection.length == 0, selection.location >= 0, selection.location <= text.utf16.count,
              let caret = Range(selection, in: text)?.lowerBound else { return nil }
        var prefix = text[..<caret]
        let hasSpace = prefix.last == " "
        guard hasSpace || caret == text.endIndex || text[caret].isWhitespace else { return nil }
        if hasSpace { prefix = prefix.dropLast() }
        let start = prefix.lastIndex(where: \.isWhitespace).map { prefix.index(after: $0) } ?? prefix.startIndex
        let token = String(prefix[start...])
        guard token.hasPrefix("/"), token.count > 1 else { return nil }
        let applicable = snippets.filter { $0.onlyInBundleID == nil || $0.onlyInBundleID == context.bundleID }
        guard let rule = applicable.first(where: { $0.trigger.lowercased() == token.lowercased() }) else { return nil }
        if !hasSpace, applicable.contains(where: {
            $0.trigger.count > token.count && $0.trigger.lowercased().hasPrefix(token.lowercased())
        }) { return nil }

        let expanded = SnippetExpander(snippets: [rule], sayPrefix: false, context: context).expand(rule.trigger)
        guard expanded.used == [rule.trigger] else { return nil }
        let range = NSRange(start..<prefix.endIndex, in: text)
        let offset = expanded.cursorOffset.map { expanded.text.prefix($0).utf16.count }
            ?? (expanded.text.utf16.count + (hasSpace ? 1 : 0))
        return TypedSnippetExpansion(range: range, text: expanded.text,
                                     caretUTF16: range.location + offset, trigger: rule.trigger)
    }
}
