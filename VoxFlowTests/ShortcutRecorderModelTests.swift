import AppKit
import Testing
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("Shortcut recorder") @MainActor
struct ShortcutRecorderModelTests {
    @Test("modifier prefix stays a draft until release; a chord saves its key")
    func modifierPrefix() {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let model = ShortcutRecorderModel(settings: settings)
        model.begin(.pushToTalk)
        model.modifiersChanged(.option)
        #expect(model.isRecording)
        #expect(model.candidate?.keycaps == ["⌥"])
        #expect(settings.shortcuts[.pushToTalk] == ShortcutAction.pushToTalk.defaultBinding)
        model.keyDown(code: 49, flags: .option, label: " ")
        #expect(!model.isRecording)
        #expect(settings.shortcuts[.pushToTalk].keycaps == ["⌥", "Space"])
    }

    @Test("a single modifier saves on release, but releasing a chord in stages cannot save its last modifier")
    func modifierRelease() {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let model = ShortcutRecorderModel(settings: settings)
        model.begin(.pushToTalk)
        model.modifiersChanged(.control)
        model.modifiersChanged([])
        #expect(settings.shortcuts[.pushToTalk].keycaps == ["⌃"])
        model.begin(.pushToTalk)
        model.modifiersChanged([.control, .option])
        model.modifiersChanged(.option)
        model.modifiersChanged([])
        #expect(model.isRecording)
        #expect(model.conflict == .invalid(.modifierRequired))
        #expect(settings.shortcuts[.pushToTalk].keycaps == ["⌃"])
    }

    @Test("system conflicts wait for explicit override; choosing another clears the candidate")
    func systemConflict() {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let model = ShortcutRecorderModel(settings: settings, systemConflict: { _ in "Spotlight" })
        model.begin(.handsFree)
        model.keyDown(code: 49, flags: .option, label: " ")
        #expect(model.conflict == .system("Spotlight"))
        #expect(settings.shortcuts[.handsFree] == ShortcutAction.handsFree.defaultBinding)
        model.chooseAnother()
        #expect(model.candidate == nil)
        #expect(model.conflict == nil)
        model.keyDown(code: 49, flags: .option, label: " ")
        model.useAnyway()
        #expect(!model.isRecording)
        #expect(settings.shortcuts[.handsFree].keycaps == ["⌥", "Space"])
    }

    @Test("internal and reserved conflicts cannot be overridden, including a changed configuration")
    func nonOverridableConflicts() {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let model = ShortcutRecorderModel(settings: settings, systemConflict: { _ in "macOS" })
        model.begin(.handsFree)
        model.keyDown(code: 9, flags: [.option, .command], label: "v")
        #expect(model.conflict == .action(.reinsert))
        model.useAnyway()
        #expect(model.isRecording)
        model.chooseAnother()
        model.keyDown(code: 48, flags: .command, label: "Tab")
        #expect(model.conflict == .invalid(.reservedSystem))
        model.useAnyway()
        #expect(settings.shortcuts[.handsFree] == ShortcutAction.handsFree.defaultBinding)
        model.chooseAnother()
        model.keyDown(code: 40, flags: .command, label: "k")
        #expect(settings.setShortcut(ShortcutBinding(keyCode: 40, modifiers: .command, label: "K"), for: .reinsert))
        model.useAnyway()
        #expect(model.conflict == .action(.reinsert))
        #expect(settings.shortcuts.isValid)
    }

    @Test("cancel, repeat and events after dismissal cannot change settings, including a custom Cancel binding")
    func cancellation() {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let model = ShortcutRecorderModel(settings: settings)
        model.begin(.handsFree)
        model.keyDown(code: 40, flags: .command, label: "k", isRepeat: true)
        #expect(model.candidate == nil)
        model.keyDown(code: 53, flags: [], label: "esc")
        #expect(!model.isRecording)
        model.keyDown(code: 40, flags: .command, label: "k")
        #expect(settings.shortcuts == DictationShortcuts())
        let customCancel = ShortcutBinding(keyCode: 40, modifiers: .control, label: "K")
        #expect(settings.setShortcut(customCancel, for: .cancel))
        model.begin(.cancel)
        model.keyDown(code: 53, flags: [], label: "esc")
        #expect(!model.isRecording)
        #expect(settings.shortcuts[.cancel] == customCancel)
        model.begin(.cancel)
        model.useDefault()
        #expect(settings.shortcuts[.cancel] == ShortcutAction.cancel.defaultBinding)
    }

    @Test("Escape dismisses a conflict and immediately resumes monitoring")
    func cancelConflict() {
        let model = ShortcutRecorderModel(settings: DictationSettings(store: InMemoryKeyValueStore()), systemConflict: { _ in "macOS" })
        var states: [Bool] = []
        model.onRecordingChange = { states.append(model.isRecording) }
        model.begin(.handsFree)
        model.keyDown(code: 49, flags: .option, label: " ")
        model.keyDown(code: 53, flags: [], label: "esc")
        #expect(!model.isRecording)
        #expect(states == [true, false])
    }

    @Test("Return chooses another shortcut after conflict, and modified Return stays a recordable key")
    func defaultConflictAction() {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let model = ShortcutRecorderModel(settings: settings, systemConflict: { $0.keyCode == 49 ? "macOS" : nil })
        model.begin(.handsFree)
        model.keyDown(code: 49, flags: .option, label: " ")
        model.keyDown(code: 36, flags: [], label: "Return")
        #expect(model.conflict == nil && model.candidate == nil)
        model.keyDown(code: 36, flags: .command, label: "Return")
        #expect(settings.shortcuts[.handsFree].keycaps == ["⌘", "Return"])
    }

    @Test("choosing another shortcut reclaims the native sheet responder only once")
    func nativeFocus() throws {
        let model = ShortcutRecorderModel(settings: DictationSettings(store: InMemoryKeyValueStore()), systemConflict: { _ in "macOS" })
        model.begin(.handsFree)
        let capture = ShortcutRecorderInput.CaptureView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = capture
        defer { window.close() }
        try #require(window.firstResponder === capture)
        model.keyDown(code: 49, flags: .option, label: " ")
        let buttonFocus = FocusSink(frame: .zero)
        capture.addSubview(buttonFocus)
        try #require(window.makeFirstResponder(buttonFocus))
        model.chooseAnother()
        capture.updateModel(model)
        #expect(window.firstResponder === capture)
        // Ordinary view updates must allow keyboard navigation to Cancel/default buttons.
        try #require(window.makeFirstResponder(buttonFocus))
        capture.updateModel(model)
        #expect(window.firstResponder === buttonFocus)
    }

    private final class FocusSink: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @Test("default restoration respects system conflicts and clears the previous recording")
    func defaults() {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let model = ShortcutRecorderModel(settings: settings, systemConflict: { $0.flags == .function ? "Change input source" : nil })
        model.begin(.handsFree)
        model.useDefault()
        #expect(model.conflict == .system("Change input source"))
        #expect(model.candidate?.doubleTap == true)
        model.cancel()
        model.begin(.reinsert)
        #expect(model.candidate == nil)
        #expect(model.conflict == nil)
        model.useDefault()
        #expect(!model.isRecording)
    }
}
