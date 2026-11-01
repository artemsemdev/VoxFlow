import AppKit
import VoxFlowCore

/// Captures only an editor owned by this process. It never requests Accessibility permission.
@MainActor
final class InAppTextInserter: LiveTextInserting {
    private let pasteboard: any Pasteboard
    private let focusedEditor: @MainActor () -> NSTextView?
    private var target: InAppTextTarget?
    private var anchor: (text: String?, selection: NSRange?)?
    private var live: LiveAccessibilityInsertion?

    init(pasteboard: any Pasteboard,
         focusedEditor: @escaping @MainActor () -> NSTextView? = InAppTextTarget.focusedEditor) {
        self.pasteboard = pasteboard
        self.focusedEditor = focusedEditor
    }

    func captureFocus(app: FrontmostApp) async {
        target = nil; anchor = nil; live = nil
        guard app.processID == ProcessInfo.processInfo.processIdentifier,
              let editor = focusedEditor(), editor.isEditable else { return }
        target = InAppTextTarget(editor)
        anchor = (target?.textValue, target?.selectedRange)
    }

    func beginLiveInsertion(_ context: LiveInsertionContext) async {
        guard context.isActive else { return }
        live = LiveAccessibilityInsertion(context: context, target: target, appName: "VoxFlow",
            initialText: anchor?.text, initialSelection: anchor?.selection,
            // The target is an in-process NSTextView, so no cross-process permission is needed.
            canAccessTarget: { true }, pasteboard: pasteboard,
            focusTarget: { [focusedEditor] in focusedEditor().map(InAppTextTarget.init) })
    }

    func updateLiveInsertion(_ text: String, context: LiveInsertionContext) async {
        guard live?.context.id == context.id else { return }
        live?.update(text)
    }

    func cancelLiveInsertion(_ context: LiveInsertionContext) async {
        guard live?.context.id == context.id else { return }
        live = nil; target = nil; anchor = nil
    }

    func finishLiveInsertion(_ text: String, cursorOffset: Int?, context: LiveInsertionContext) async -> InsertionResult? {
        guard context.isActive, let live, live.context.id == context.id else { return nil }
        defer { self.live = nil; target = nil; anchor = nil }
        return live.finish(text, cursorOffset: cursorOffset)
    }

    func insert(_ text: String, cursorOffset: Int?) async -> InsertionResult {
        let context = LiveInsertionContext { true }
        await beginLiveInsertion(context)
        // This context remains active for the entire synchronous editor transaction.
        return await finishLiveInsertion(text, cursorOffset: cursorOffset, context: context)
            ?? .copiedToClipboard(reason: .insertionFailed)
    }
}

@MainActor
final class InAppTextTarget: AccessibilityTextTarget {
    private weak var editor: NSTextView?
    init(_ editor: NSTextView) { self.editor = editor }

    static func focusedEditor() -> NSTextView? {
        guard NSApp.isActive, let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
              editor.isEditable, !(editor.delegate is NSSecureTextField) else { return nil }
        return editor
    }

    var isEditable: Bool { editor?.isEditable == true }
    var textValue: String? { editor?.string }
    var selectedRange: NSRange? { editor?.selectedRange() }

    func isSameTarget(as other: any AccessibilityTextTarget) -> Bool {
        guard let editor, let other = other as? InAppTextTarget else { return false }
        return editor === other.editor
    }

    func replaceSelectedText(_ text: String) -> Bool {
        guard let editor, editor.isEditable else { return false }
        let range = editor.selectedRange()
        guard valid(range, in: editor.string) else { return false }
        let expected = (editor.string as NSString).replacingCharacters(in: range, with: text)
        // AppKit's normal editing path preserves undo, delegates and SwiftUI bindings.
        editor.insertText(text, replacementRange: range)
        return editor.string == expected
    }

    func setSelectedRange(_ range: NSRange) -> Bool {
        guard let editor, valid(range, in: editor.string) else { return false }
        editor.setSelectedRange(range)
        return editor.selectedRange() == range
    }

    private func valid(_ range: NSRange, in text: String) -> Bool {
        range.location >= 0 && range.location <= text.utf16.count && range.length >= 0
            && range.length <= text.utf16.count - range.location
    }
}
