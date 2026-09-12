import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("Accessibility insertion", .timeLimit(.minutes(1)))
@MainActor
struct AccessibilityTextInserterTests {
    final class Target: AccessibilityTextTarget {
        var isEditable = true
        var selectedRange: NSRange? = NSRange(location: 10, length: 4)
        var acceptsText = true
        var acceptsSelection = true
        var texts: [String] = []
        var selections: [NSRange] = []
        func replaceSelectedText(_ text: String) -> Bool {
            guard acceptsText else { return false }
            texts.append(text)
            // A target normally moves the caret to the end as it inserts/replaces text.
            if let range = selectedRange { selectedRange = NSRange(location: range.location + text.utf16.count, length: 0) }
            return true
        }
        func setSelectedRange(_ range: NSRange) -> Bool {
            guard acceptsSelection else { return false }
            selections.append(range)
            selectedRange = range
            return true
        }
    }

    @Test("denied or revoked Accessibility copies with its reason and never writes", arguments: [false, true])
    func deniedAccessibility(revoked: Bool) async {
        let permissions = FakePermissions(microphone: .granted, requestResult: .granted, accessibility: revoked)
        let target = Target(), clipboard = FakePasteboard()
        var captures = 0
        let inserter = AccessibilityTextInserter(permissions: permissions, pasteboard: clipboard,
                                                focusTarget: { captures += 1; return target })
        await inserter.captureFocus(app: FrontmostApp(name: "TextEdit", bundleID: "com.apple.TextEdit"))
        permissions.accessibility = false
        #expect(await inserter.insert("keep this text") == .copiedToClipboard(reason: .accessibilityDenied))
        await inserter.captureFocus(app: FrontmostApp(name: "TextEdit", bundleID: "com.apple.TextEdit"))
        #expect(await inserter.insert("second text") == .copiedToClipboard(reason: .accessibilityDenied))
        #expect(captures == (revoked ? 1 : 0))
        #expect(target.texts.isEmpty && target.selections.isEmpty)
        #expect(clipboard.strings == ["keep this text", "second text"])
        #expect(permissions.prompted == 1)
    }

    @Test("trusted capture without an editable field reports noTextField", arguments: [false, true])
    func noField(missing: Bool) async {
        let permissions = FakePermissions(microphone: .granted, requestResult: .granted, accessibility: true)
        let target = Target(), clipboard = FakePasteboard()
        target.isEditable = false
        let inserter = AccessibilityTextInserter(permissions: permissions, pasteboard: clipboard,
                                                focusTarget: { missing ? nil : target })
        await inserter.captureFocus(app: FrontmostApp(name: "Finder", bundleID: "com.apple.finder"))
        #expect(await inserter.insert("keep this text") == .copiedToClipboard(reason: .noTextField))
        #expect(clipboard.strings == ["keep this text"] && target.texts.isEmpty)
    }

    private func makeInserter(_ target: Target, clipboard: FakePasteboard = FakePasteboard()) -> AccessibilityTextInserter {
        AccessibilityTextInserter(permissions: FakePermissions(microphone: .granted, requestResult: .granted, accessibility: true),
                                  pasteboard: clipboard, focusTarget: { target })
    }

    @Test("caret is relative to the replaced selection and converted from Characters to UTF-16",
          arguments: [(0, 10), (6, 16), (7, 23), (8, 25), (14, 31)])
    func caret(offset: Int, expectedPosition: Int) async {
        let target = Target()
        let inserter = makeInserter(target)
        await inserter.captureFocus(app: FrontmostApp(name: "Mail", bundleID: "com.apple.mail"))
        let text = "Best,\n👩🏽‍💻e\u{301}\nArtem"
        #expect(await inserter.insert(text, cursorOffset: offset) == .inserted(appName: "Mail"))
        #expect(target.texts == [text])
        #expect(target.selections == [NSRange(location: expectedPosition, length: 0)])
        #expect(await inserter.insert("next", cursorOffset: 0) == .copiedToClipboard(reason: .noTextField))
        #expect(target.texts == [text]) // consumed focus cannot be reused
    }

    @Test("absent or invalid cursor positions preserve normal insertion", arguments: [nil, -1, 100, Int.max] as [Int?])
    func noCaret(offset: Int?) async {
        let target = Target()
        let inserter = makeInserter(target)
        await inserter.captureFocus(app: FrontmostApp(name: "Mail", bundleID: "com.apple.mail"))
        #expect(await inserter.insert("Best,\n\nArtem", cursorOffset: offset) == .inserted(appName: "Mail"))
        #expect(target.selections.isEmpty)
    }

    @Test("unsupported selection never turns a successful insertion into clipboard fallback", arguments: [false, true])
    func unsupportedSelection(missingRange: Bool) async {
        let target = Target()
        target.acceptsSelection = false
        if missingRange { target.selectedRange = nil }
        let clipboard = FakePasteboard()
        let inserter = makeInserter(target, clipboard: clipboard)
        await inserter.captureFocus(app: FrontmostApp(name: "Mail", bundleID: "com.apple.mail"))
        #expect(await inserter.insert("Best,\n\nArtem", cursorOffset: 6) == .inserted(appName: "Mail"))
        #expect(target.texts == ["Best,\n\nArtem"])
        #expect(target.selections.isEmpty)
        #expect(clipboard.strings.isEmpty)
    }

    @Test("failed insertion copies the expanded text without moving selection")
    func failedInsertion() async {
        let target = Target()
        target.acceptsText = false
        let clipboard = FakePasteboard()
        let inserter = makeInserter(target, clipboard: clipboard)
        await inserter.captureFocus(app: FrontmostApp(name: "Mail", bundleID: "com.apple.mail"))
        #expect(await inserter.insert("Best,\n\nArtem", cursorOffset: 6) == .copiedToClipboard(reason: .insertionFailed))
        #expect(clipboard.strings == ["Best,\n\nArtem"])
        #expect(target.selections.isEmpty)
    }
}
