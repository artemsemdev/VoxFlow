import Foundation
import Testing
@testable import VoxFlowStyling

@Suite("SnippetExpander")
struct SnippetExpanderTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14

    private func expander(
        snippets: [SnippetRule],
        sayPrefix: Bool = false,
        clipboard: String? = nil,
        appName: String? = nil,
        bundleID: String? = nil
    ) -> SnippetExpander {
        SnippetExpander(
            snippets: snippets,
            sayPrefix: sayPrefix,
            context: (date: fixedDate, clipboard: clipboard, appName: appName, bundleID: bundleID)
        )
    }

    @Test("expands the slash form of a trigger")
    func slashForm() {
        let rule = SnippetRule(trigger: "/sig", body: "Best, Artem")
        let result = expander(snippets: [rule]).expand("Thanks, /sig")
        #expect(result.text == "Thanks, Best, Artem")
        #expect(result.used == ["/sig"])
    }

    @Test("expands the spoken form 'slash trigger'")
    func spokenForm() {
        let rule = SnippetRule(trigger: "/sig", body: "Best, Artem")
        let result = expander(snippets: [rule]).expand("Thanks, slash sig")
        #expect(result.text == "Thanks, Best, Artem")
        #expect(result.used == ["/sig"])
    }

    @Test("spoken form matches case-insensitively")
    func spokenFormCaseInsensitive() {
        let rule = SnippetRule(trigger: "/sig", body: "Best, Artem")
        let result = expander(snippets: [rule]).expand("Thanks, Slash Sig")
        #expect(result.text == "Thanks, Best, Artem")
        #expect(result.used == ["/sig"])
    }

    @Test("with sayPrefix, the trigger alone is not expanded")
    func sayPrefixRequiresSnippetWord() {
        let rule = SnippetRule(trigger: "/sig", body: "Best, Artem")
        let result = expander(snippets: [rule], sayPrefix: true).expand("Thanks, /sig")
        #expect(result.text == "Thanks, /sig")
        #expect(result.used.isEmpty)
    }

    @Test("with sayPrefix, 'snippet slash sig' expands and consumes the prefix")
    func sayPrefixSpokenForm() {
        let rule = SnippetRule(trigger: "/sig", body: "Best, Artem")
        let result = expander(snippets: [rule], sayPrefix: true).expand("Thanks, snippet slash sig")
        #expect(result.text == "Thanks, Best, Artem")
        #expect(result.used == ["/sig"])
    }

    @Test("with sayPrefix, 'snippet /sig' expands and consumes the prefix")
    func sayPrefixSlashForm() {
        let rule = SnippetRule(trigger: "/sig", body: "Best, Artem")
        let result = expander(snippets: [rule], sayPrefix: true).expand("Thanks, snippet /sig")
        #expect(result.text == "Thanks, Best, Artem")
        #expect(result.used == ["/sig"])
    }

    @Test("onlyInBundleID mismatch leaves the text untouched")
    func onlyInBundleIDMismatch() {
        let rule = SnippetRule(trigger: "/sig", body: "Best, Artem", onlyInBundleID: "com.example.mail")
        let result = expander(snippets: [rule], bundleID: "com.example.notes").expand("Thanks, /sig")
        #expect(result.text == "Thanks, /sig")
        #expect(result.used.isEmpty)
    }

    @Test("onlyInBundleID match expands normally")
    func onlyInBundleIDMatch() {
        let rule = SnippetRule(trigger: "/sig", body: "Best, Artem", onlyInBundleID: "com.example.mail")
        let result = expander(snippets: [rule], bundleID: "com.example.mail").expand("Thanks, /sig")
        #expect(result.text == "Thanks, Best, Artem")
        #expect(result.used == ["/sig"])
    }

    @Test("cursor placeholder is removed and its offset in the final text is reported")
    func cursorOffset() {
        let rule = SnippetRule(trigger: "/greet", body: "Hi cursor, thanks")
        let result = expander(snippets: [rule]).expand("/greet")
        #expect(result.text == "Hi , thanks")
        #expect(result.cursorOffset == 3)
    }

    @Test("cursor offset is computed after date/clipboard/app placeholders are substituted")
    func cursorOffsetAfterOtherPlaceholders() {
        let rule = SnippetRule(trigger: "/app", body: "app: cursor")
        let result = expander(snippets: [rule], appName: "Mail").expand("/app")
        #expect(result.text == "Mail: ")
        #expect(result.cursorOffset == 6)
    }

    @Test("date placeholder replaces every occurrence in the body")
    func datePlaceholderReplacesAllOccurrences() {
        let rule = SnippetRule(trigger: "/today", body: "date to date")
        let expected = DateFormatter.localizedString(from: fixedDate, dateStyle: .medium, timeStyle: .none)
        let result = expander(snippets: [rule]).expand("/today")
        #expect(result.text == "\(expected) to \(expected)")
    }

    @Test("clipboard placeholder replaces every occurrence in the body")
    func clipboardPlaceholderReplacesAllOccurrences() {
        let rule = SnippetRule(trigger: "/paste", body: "clipboard and clipboard again")
        let result = expander(snippets: [rule], clipboard: "hi").expand("/paste")
        #expect(result.text == "hi and hi again")
    }

    @Test("app placeholder replaces every occurrence in the body")
    func appPlaceholderReplacesAllOccurrences() {
        let rule = SnippetRule(trigger: "/where", body: "app told app")
        let result = expander(snippets: [rule], appName: "Notes").expand("/where")
        #expect(result.text == "Notes told Notes")
    }

    @Test("a second cursor occurrence is removed from the output; the first sets the offset")
    func secondCursorOccurrenceIsRemoved() {
        let rule = SnippetRule(trigger: "/greet", body: "Hi cursor, thanks cursor!")
        let result = expander(snippets: [rule]).expand("/greet")
        #expect(result.text == "Hi , thanks !")
        #expect(result.cursorOffset == 3)
    }

    @Test("date placeholder expands to a medium-style date")
    func datePlaceholder() {
        let rule = SnippetRule(trigger: "/today", body: "Today is date")
        let expected = DateFormatter.localizedString(from: fixedDate, dateStyle: .medium, timeStyle: .none)
        let result = expander(snippets: [rule]).expand("/today")
        #expect(result.text == "Today is \(expected)")
    }

    @Test("clipboard placeholder expands to the current pasteboard string")
    func clipboardPlaceholder() {
        let rule = SnippetRule(trigger: "/paste", body: "You said: clipboard")
        let result = expander(snippets: [rule], clipboard: "hello world").expand("/paste")
        #expect(result.text == "You said: hello world")
    }

    @Test("nil clipboard expands to an empty string")
    func nilClipboardPlaceholder() {
        let rule = SnippetRule(trigger: "/paste", body: "You said: clipboard")
        let result = expander(snippets: [rule], clipboard: nil).expand("/paste")
        #expect(result.text == "You said: ")
    }

    @Test("app placeholder expands to the app name")
    func appPlaceholder() {
        let rule = SnippetRule(trigger: "/where", body: "You're in app")
        let result = expander(snippets: [rule], appName: "Notes").expand("/where")
        #expect(result.text == "You're in Notes")
    }

    @Test("multiple different snippets in one text all expand, used lists both in order")
    func multipleSnippets() {
        let sig = SnippetRule(trigger: "/sig", body: "Artem")
        let greet = SnippetRule(trigger: "/hi", body: "Hello")
        let result = expander(snippets: [sig, greet]).expand("/hi there, /sig")
        #expect(result.text == "Hello there, Artem")
        #expect(result.used == ["/hi", "/sig"])
    }

    @Test("no matching trigger leaves text untouched with an empty used list")
    func noMatch() {
        let rule = SnippetRule(trigger: "/sig", body: "Artem")
        let result = expander(snippets: [rule]).expand("no trigger here")
        #expect(result.text == "no trigger here")
        #expect(result.used.isEmpty)
        #expect(result.cursorOffset == nil)
    }
}
