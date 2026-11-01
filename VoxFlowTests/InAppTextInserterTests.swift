import AppKit
import Synchronization
import Testing
import VoxFlowCore
@testable import VoxFlow

@Suite("In-app insertion stays in the captured editor") @MainActor
struct InAppTextInserterTests {
    private var ownApp: FrontmostApp {
        FrontmostApp(name: "VoxFlow", bundleID: "test", processID: ProcessInfo.processInfo.processIdentifier)
    }

    @Test func replacesSelectionAndPlacesUnicodeCursor() async {
        let editor = NSTextView()
        editor.string = "prefix old suffix"
        editor.setSelectedRange(NSRange(location: 7, length: 3))
        let clipboard = FakePasteboard()
        let inserter = InAppTextInserter(pasteboard: clipboard, focusedEditor: { editor })
        await inserter.captureFocus(app: ownApp)
        #expect(await inserter.insert("🌱 garden", cursorOffset: 1) == .inserted(appName: "VoxFlow"))
        #expect(editor.string == "prefix 🌱 garden suffix")
        #expect(editor.selectedRange() == NSRange(location: 9, length: 0))
        #expect(clipboard.strings.isEmpty)
    }

    @Test func foreignProcessCannotCaptureAnEditor() async {
        let editor = NSTextView()
        editor.string = "untouched"
        var reads = 0
        let clipboard = FakePasteboard()
        let inserter = InAppTextInserter(pasteboard: clipboard, focusedEditor: { reads += 1; return editor })
        await inserter.captureFocus(app: FrontmostApp(name: "Other", bundleID: "other", processID: -1))
        #expect(await inserter.insert("preserve this") == .copiedToClipboard(reason: .noTextField))
        #expect(reads == 0 && editor.string == "untouched")
        #expect(clipboard.strings == ["preserve this"])
    }

    @Test func focusChangePreservesBothEditorsAndCopiesFinalText() async {
        let first = NSTextView(), second = NSTextView()
        second.string = "another draft"
        let focus = EditorFocus(first)
        let clipboard = FakePasteboard()
        let inserter = InAppTextInserter(pasteboard: clipboard, focusedEditor: { focus.editor })
        await inserter.captureFocus(app: ownApp)
        let context = LiveInsertionContext { true }
        await inserter.beginLiveInsertion(context)
        await inserter.updateLiveInsertion("Basil", context: context)
        focus.editor = second
        #expect(await inserter.finishLiveInsertion("Basil and mint", cursorOffset: nil, context: context)
            == .copiedToClipboard(reason: .insertionFailed))
        #expect(first.string == "Basil" && second.string == "another draft")
        #expect(clipboard.strings == ["Basil and mint"])
    }

    @Test func manualEditsAndCancellationArePreserved() async {
        let editor = NSTextView()
        let clipboard = FakePasteboard()
        let inserter = InAppTextInserter(pasteboard: clipboard, focusedEditor: { editor })
        await inserter.captureFocus(app: ownApp)
        let active = Mutex(true)
        let context = LiveInsertionContext { active.withLock { $0 } }
        await inserter.beginLiveInsertion(context)
        await inserter.updateLiveInsertion("Basil", context: context)
        editor.string = "My correction"
        #expect(await inserter.finishLiveInsertion("Basil and mint", cursorOffset: nil, context: context)
            == .copiedToClipboard(reason: .insertionFailed))
        #expect(editor.string == "My correction")
        await inserter.captureFocus(app: ownApp)
        await inserter.beginLiveInsertion(context)
        active.withLock { $0 = false }
        await inserter.updateLiveInsertion("late result", context: context)
        #expect(await inserter.finishLiveInsertion("late result", cursorOffset: nil, context: context) == nil)
        #expect(editor.string == "My correction" && clipboard.strings == ["Basil and mint"])
    }
}

@MainActor private final class EditorFocus {
    var editor: NSTextView
    init(_ editor: NSTextView) { self.editor = editor }
}
