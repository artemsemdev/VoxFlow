import Foundation
import Testing
import VoxFlowStyling
@testable import VoxFlow

@Suite("Typed snippet delivery")
@MainActor
struct TypedSnippetReplacementTests {
    private func expansion(_ value: String, body: String = "Best,\nArtem") throws -> TypedSnippetExpansion {
        try #require(SnippetExpander(snippets: [SnippetRule(trigger: "/sig", body: body)],
                                    sayPrefix: false, context: (Date(), nil, nil, nil))
            .expandTyped(in: value, selection: NSRange(location: value.utf16.count, length: 0)))
    }

    @Test("native text fields replace just the trigger and place the caret")
    func native() throws {
        let target = SnippetTarget("Hello /sig")
        let edit = try expansion(target.value)
        #expect(TypedSnippetReplacement.apply(edit, in: target.value, selection: target.range,
            target: target, isValid: { true }, sendKeys: { _ in Issue.record("Unexpected keyboard fallback"); return false }))
        #expect(target.value == "Hello Best,\nArtem")
        #expect(target.range == NSRange(location: target.value.utf16.count, length: 0))
    }

    @Test("Electron's successful but ineffective AX setter is never used")
    func chromium() throws {
        let target = SnippetTarget("/sig", native: false)
        var sent: TypedSnippetReplacement.KeyboardEdit?
        #expect(TypedSnippetReplacement.apply(try expansion(target.value), in: target.value,
            selection: target.range, target: target, isValid: { true }, sendKeys: { sent = $0; return true }))
        #expect(sent == .init(deleteCount: 4, text: "Best,\nArtem", moveLeft: 0))
        #expect(target.selectionWrites.isEmpty)
        #expect(target.textWrites == 0)
    }

    @Test("keyboard replacement preserves a trailing space and a Unicode cursor placeholder")
    func keyboardCaret() throws {
        let target = SnippetTarget("Prefix 😀 /sig ", native: false)
        var sent: TypedSnippetReplacement.KeyboardEdit?
        #expect(TypedSnippetReplacement.apply(try expansion(target.value, body: "Hi {cursor}👋🏽!"),
            in: target.value, selection: target.range, target: target, isValid: { true },
            sendKeys: { sent = $0; return true }))
        #expect(sent == .init(deleteCount: 5, text: "Hi 👋🏽! ", moveLeft: 3))
    }

    @Test("changed focus or text prevents edits", arguments: [true, false])
    func staleTarget(focusChanged: Bool) throws {
        let target = SnippetTarget("/sig")
        let edit = try expansion(target.value)
        if !focusChanged { target.value = "new text" }
        #expect(!TypedSnippetReplacement.apply(edit, in: "/sig", selection: NSRange(location: 4, length: 0),
            target: target, isValid: { !focusChanged }, sendKeys: { _ in Issue.record("Stale target"); return true }))
        #expect(target.selectionWrites.isEmpty)
        #expect(target.textWrites == 0)
    }

    @Test("focus lost after selecting the trigger prevents insertion and selection restoration")
    func focusLostOnSelection() throws {
        let target = SnippetTarget("/sig")
        var valid = true
        target.onSelection = { valid = false }
        #expect(!TypedSnippetReplacement.apply(try expansion(target.value), in: target.value,
            selection: target.range, target: target, isValid: { valid }, sendKeys: { _ in false }))
        #expect(target.textWrites == 0)
        #expect(target.selectionWrites.count == 1)
    }

    @Test("a failed native setter restores the original caret without changing text")
    func failedNativeWrite() throws {
        let target = SnippetTarget("/sig")
        target.replaceSucceeds = false
        #expect(!TypedSnippetReplacement.apply(try expansion(target.value), in: target.value,
            selection: target.range, target: target, isValid: { true }, sendKeys: { _ in false }))
        #expect(target.value == "/sig")
        #expect(target.range == NSRange(location: 4, length: 0))
    }

    @Test("a failed keyboard delivery does not report a successful expansion")
    func failedKeyboardWrite() throws {
        let target = SnippetTarget("/sig", native: false)
        #expect(!TypedSnippetReplacement.apply(try expansion(target.value), in: target.value,
            selection: target.range, target: target, isValid: { true }, sendKeys: { _ in false }))
        #expect(target.selectionWrites.isEmpty)
        #expect(target.textWrites == 0)
    }
}

@MainActor
private final class SnippetTarget: AccessibilityTextTarget {
    var value: String
    var range: NSRange
    let supportsLiveInsertion: Bool
    var selectionWrites: [NSRange] = []
    var textWrites = 0
    var replaceSucceeds = true
    var onSelection: () -> Void = {}
    var isEditable: Bool { true }
    var textValue: String? { value }
    var selectedRange: NSRange? { range }

    init(_ value: String, native: Bool = true) {
        self.value = value
        range = NSRange(location: value.utf16.count, length: 0)
        supportsLiveInsertion = native
    }

    func setSelectedRange(_ range: NSRange) -> Bool {
        selectionWrites.append(range)
        self.range = range
        onSelection()
        return true
    }

    func replaceSelectedText(_ text: String) -> Bool {
        textWrites += 1
        guard replaceSucceeds else { return false }
        if supportsLiveInsertion {
            value = (value as NSString).replacingCharacters(in: range, with: text)
            range = NSRange(location: range.location + text.utf16.count, length: 0)
        }
        return true
    }
}
