import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("Capture-owned Accessibility insertion") @MainActor
struct AccessibilityLiveInsertionTests {
    final class Target: AccessibilityTextTarget {
        var isEditable = true
        var textValue: String? = "prefix: old suffix"
        var selectedRange: NSRange? = NSRange(location: 8, length: 3)
        var writes: [String] = []
        func replaceSelectedText(_ text: String) -> Bool {
            guard let value = textValue, let range = selectedRange else { return false }
            textValue = (value as NSString).replacingCharacters(in: range, with: text)
            selectedRange = NSRange(location: range.location + text.utf16.count, length: 0)
            writes.append(text)
            return true
        }
        func setSelectedRange(_ range: NSRange) -> Bool { selectedRange = range; return true }
    }
    @MainActor final class Harness {
        let target = Target(), other = Target(), clipboard = FakePasteboard()
        let active = Flag()
        var current: Target?
        lazy var context = LiveInsertionContext { [active] in active.value }
        lazy var inserter = AccessibilityTextInserter(
            permissions: FakePermissions(microphone: .granted, requestResult: .granted, accessibility: true),
            pasteboard: clipboard, focusTarget: { [weak self] in self?.current })
        init() { current = target }
        func begin() async {
            await inserter.captureFocus(app: FrontmostApp(name: "TextEdit", bundleID: "com.apple.TextEdit"))
            await inserter.beginLiveInsertion(context)
        }
        func update(_ text: String) async { await inserter.updateLiveInsertion(text, context: context) }
        func finish(_ text: String, cursor: Int? = nil) async -> InsertionResult? {
            await inserter.finishLiveInsertion(text, cursorOffset: cursor, context: context)
        }
    }
    final class Flag: Sendable {
        let storage = Mutex(true)
        var value: Bool { storage.withLock { $0 } }
        func cancel() { storage.withLock { $0 = false } }
    }
    @Test("two cumulative windows append only their delta; final styling replaces the owned range once")
    func cumulative() async {
        let h = Harness(); await h.begin()
        await h.update("hello"); await h.update("hello world")
        #expect(h.target.writes == ["hello", " world"])
        #expect(h.clipboard.strings.isEmpty)
        #expect(await h.finish("Hello, world!") == .inserted(appName: "TextEdit"))
        #expect(h.target.textValue == "prefix: Hello, world! suffix")
        #expect(h.target.writes == ["hello", " world", "Hello, world!"])
        #expect(await h.finish("Hello, world!") == nil)
    }
    @Test("Unicode corrections use UTF-16 boundaries and final snippet caret is relative to insertion")
    func unicode() async {
        let h = Harness(); await h.begin()
        await h.update("A 👩🏽‍💻 cafe\u{301}!")
        await h.update("A 👩🏽‍💻 café?")
        #expect(h.target.writes == ["A 👩🏽‍💻 cafe\u{301}!", "é?"])
        #expect(await h.finish("Best,\n👩🏽‍💻\nArtem", cursor: 7) == .inserted(appName: "TextEdit"))
        #expect(h.target.selectedRange == NSRange(location: 8 + "Best,\n👩🏽‍💻".utf16.count, length: 0))
    }
    @Test("observed focus loss or user edits stop all later writes and copy the full final text once",
          arguments: ["focus", "text", "selection"])
    func ownershipLost(change: String) async {
        let h = Harness(); await h.begin(); await h.update("hello")
        switch change {
        case "focus": h.current = h.other
        case "text": h.target.textValue = "prefix: edited suffix"
        default: h.target.selectedRange = NSRange(location: 0, length: 0)
        }
        await h.update("hello world")
        h.current = h.target // Returning to the old target must not restore lost ownership.
        #expect(await h.finish("Hello, world!") == .copiedToClipboard(reason: .insertionFailed))
        #expect(h.target.writes == ["hello"] && h.other.writes.isEmpty)
        #expect(h.clipboard.strings == ["Hello, world!"])
        #expect(await h.finish("Hello, world!") == nil)
        #expect(h.clipboard.strings.count == 1)
    }
    @Test("cancelled or superseded captures keep inserted text and reject stale updates and final writes")
    func cancelled() async {
        let h = Harness(); await h.begin(); await h.update("hello")
        h.active.cancel()
        await h.update("hello world")
        #expect(await h.finish("Hello, world!") == nil)
        #expect(h.target.writes == ["hello"] && h.clipboard.strings.isEmpty)
        let next = LiveInsertionContext { true }
        await h.inserter.beginLiveInsertion(next)
        await h.update("stale")
        #expect(h.target.writes == ["hello"])
    }

    @Test("an empty preview preserves the selected word until the final result replaces it")
    func emptyPreview() async {
        let h = Harness(); await h.begin(); await h.update("")
        #expect(h.target.textValue == "prefix: old suffix" && h.target.writes.isEmpty)
        #expect(await h.finish("Hello") == .inserted(appName: "TextEdit"))
        #expect(h.target.textValue == "prefix: Hello suffix")
    }

    @Test("unreadable text and selection changes after focus capture copy only the full final result",
          arguments: [false, true])
    func invalidAnchor(unreadable: Bool) async {
        let h = Harness()
        if unreadable { h.target.textValue = nil }
        await h.inserter.captureFocus(app: FrontmostApp(name: "TextEdit", bundleID: "com.apple.TextEdit"))
        if !unreadable { h.target.selectedRange = NSRange(location: 0, length: 0) }
        await h.inserter.beginLiveInsertion(h.context)
        await h.update("hello")
        #expect(h.target.writes.isEmpty && h.clipboard.strings.isEmpty)
        #expect(await h.finish("Hello, world!") == .copiedToClipboard(reason: .insertionFailed))
        #expect(h.target.writes.isEmpty && h.clipboard.strings == ["Hello, world!"])
    }

    @Test("cancellation releases the old focus snapshot without clearing a newer live capture")
    func cancelCleanup() async {
        let h = Harness(); await h.begin(); await h.update("hello")
        h.active.cancel()
        await h.inserter.cancelLiveInsertion(h.context)
        #expect(h.target.writes == ["hello"] && h.clipboard.strings.isEmpty)
        // A new capture owns the current caret; delayed cleanup from the old one must not clear it.
        await h.inserter.captureFocus(app: FrontmostApp(name: "TextEdit", bundleID: "com.apple.TextEdit"))
        let next = LiveInsertionContext { true }
        await h.inserter.beginLiveInsertion(next)
        await h.inserter.cancelLiveInsertion(h.context)
        #expect(await h.inserter.finishLiveInsertion(" again", cursorOffset: nil, context: next) == .inserted(appName: "TextEdit"))
        #expect(h.target.textValue == "prefix: hello again suffix")
    }
}
