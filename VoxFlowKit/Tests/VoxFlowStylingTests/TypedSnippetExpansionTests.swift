import Foundation
import Testing
@testable import VoxFlowStyling

@Suite("Typed snippet expansion")
struct TypedSnippetExpansionTests {
    private func match(_ text: String, rules: [SnippetRule] = [SnippetRule(trigger: "/sig", body: "Best,\nArtem")],
                       selection: NSRange? = nil, bundleID: String? = nil) -> TypedSnippetExpansion? {
        SnippetExpander(snippets: rules, sayPrefix: true,
                        context: (Date(timeIntervalSince1970: 0), "pasted", "Notes", bundleID))
            .expandTyped(in: text, selection: selection ?? NSRange(location: text.utf16.count, length: 0))
    }

    @Test("typing the complete trigger expands without a spoken prefix")
    func completeTrigger() throws {
        let result = try #require(match("Thanks /SIG"))
        #expect(result.range == NSRange(location: 7, length: 4))
        #expect(result.text == "Best,\nArtem")
        #expect(result.caretUTF16 == 18)
        #expect(result.trigger == "/sig")
    }

    @Test("ordinary words, paths and incomplete triggers are left alone", arguments: ["sig", "/si", "https://host/sig", "word/sig", "/sig2"])
    func noMatch(text: String) { #expect(match(text) == nil) }

    @Test("selection and invalid UTF-16 offsets cannot replace text", arguments: [NSRange(location: 0, length: 4), NSRange(location: 99, length: 0), NSRange(location: -1, length: 0)])
    func invalidSelection(selection: NSRange) { #expect(match("/sig", selection: selection) == nil) }

    @Test("replacement uses UTF-16 offsets and preserves text after the caret")
    func unicodeAndMidField() throws {
        let result = try #require(match("😀 /sig suffix", selection: NSRange(location: 7, length: 0)))
        let replaced = ("😀 /sig suffix" as NSString).replacingCharacters(in: result.range, with: result.text)
        #expect(replaced == "😀 Best,\nArtem suffix")
        #expect(result.caretUTF16 == 14)
    }

    @Test("editing inside a longer token does not replace its prefix")
    func caretInsideToken() {
        #expect(match("/sig2", selection: NSRange(location: 4, length: 0)) == nil)
    }

    @Test("a longer trigger remains typeable; space completes the shorter one")
    func sharedPrefix() throws {
        let rules = [SnippetRule(trigger: "/sig", body: "Short"), SnippetRule(trigger: "/sig2", body: "Long")]
        #expect(match("/sig", rules: rules) == nil)
        #expect(match("/sig2", rules: rules)?.text == "Long")
        let result = try #require(match("/sig ", rules: rules))
        #expect(result.range == NSRange(location: 0, length: 4))
        #expect(result.caretUTF16 == 6)
    }

    @Test("Only in applies to typed triggers")
    func appScope() {
        let rules = [SnippetRule(trigger: "/sig", body: "Scoped", onlyInBundleID: "notes")]
        #expect(match("/sig", rules: rules) == nil)
        #expect(match("/sig", rules: rules, bundleID: "mail") == nil)
        #expect(match("/sig", rules: rules, bundleID: "notes")?.text == "Scoped")
    }

    @Test("placeholder expansion places the caret using UTF-16, even before a trailing space")
    func placeholders() throws {
        let rules = [SnippetRule(trigger: "/sig", body: "😀 app: cursor clipboard")]
        let result = try #require(match("/sig ", rules: rules))
        #expect(result.text == "😀 Notes:  pasted")
        #expect(result.caretUTF16 == 10)
    }
}
