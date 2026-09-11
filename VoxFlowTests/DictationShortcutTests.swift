import AppKit
import Testing
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("Dictation shortcuts")
@MainActor
struct DictationShortcutTests {
    @Test("default bindings preserve the canvas's hold, double-tap, cancel and re-insert keys")
    func defaults() {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        #expect(settings.shortcuts[.pushToTalk].keycaps == ["fn"])
        #expect(settings.shortcuts[.handsFree].keycaps == ["fn", "fn"])
        #expect(settings.shortcuts[.cancel].keycaps == ["esc"])
        #expect(settings.shortcuts[.reinsert].keycaps == ["⌥", "⌘", "V"])
        #expect(ShortcutAction.allCases.allSatisfy { settings.shortcuts[$0].validationError(for: $0) == nil })
    }

    @Test("custom bindings normalize irrelevant flags, persist and notify once")
    func persistence() {
        let store = InMemoryKeyValueStore()
        let settings = DictationSettings(store: store)
        var changes = 0
        settings.onShortcutsChange = { changes += 1 }
        let custom = ShortcutBinding(keyCode: 40, modifiers: [.control, .option, .capsLock], label: "k")
        #expect(settings.setShortcut(custom, for: .pushToTalk))
        #expect(custom.flags == [.control, .option])
        #expect(custom.keycaps == ["⌃", "⌥", "K"])
        #expect(DictationSettings(store: store).shortcuts[.pushToTalk] == custom)
        #expect(changes == 1)
        #expect(DictationSettings(store: store).shortcuts[.handsFree] == ShortcutAction.handsFree.defaultBinding)
        #expect(settings.setShortcut(custom, for: .pushToTalk))
        #expect(changes == 1)
        let handsFree = ShortcutBinding(keyCode: 49, modifiers: .option, label: " ")
        #expect(settings.setShortcut(handsFree, for: .handsFree))
        #expect(changes == 2)
        let reloaded = DictationSettings(store: store)
        #expect(reloaded.shortcuts[.pushToTalk] == custom)
        #expect(reloaded.shortcuts[.handsFree] == handsFree)
    }

    @Test("special keycaps use conventional names from their physical keycodes")
    func specialKeycaps() {
        for (code, name): (UInt16, String) in [(49, "Space"), (48, "Tab"), (36, "Return"), (51, "Delete"), (53, "esc")] {
            #expect(ShortcutBinding(keyCode: code, modifiers: .option, label: "ignored").keycaps == ["⌥", name])
        }
    }

    @Test("canvas-supported single modifiers work for push-to-talk; other bare keys require a chord")
    func bareModifiers() {
        for flag: NSEvent.ModifierFlags in [.function, .option, .control] {
            let binding = ShortcutBinding(modifiers: flag)
            #expect(binding.validationError(for: .pushToTalk) == nil)
            #expect(binding.validationError(for: .handsFree) == .modifierRequired)
        }
        #expect(ShortcutBinding(modifiers: .shift).validationError(for: .pushToTalk) == .modifierRequired)
        #expect(ShortcutBinding(keyCode: 0, label: "A").validationError(for: .pushToTalk) == .modifierRequired)
        #expect(ShortcutBinding(keyCode: 53, label: "esc").validationError(for: .cancel) == nil)
        #expect(ShortcutBinding(keyCode: 40, modifiers: .command, label: "K", doubleTap: true).validationError(for: .handsFree) == .invalidGesture)
    }

    @Test("reserved system chords cannot replace a binding; configurable system shortcuts remain candidates")
    func reserved() {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        for binding in [ShortcutBinding(keyCode: 48, modifiers: .command, label: "Tab"),
                        ShortcutBinding(keyCode: 53, modifiers: [.command, .option], label: "esc"),
                        ShortcutBinding(keyCode: 12, modifiers: [.command, .control], label: "Q"),
                        ShortcutBinding(keyCode: 12, modifiers: [.command, .shift, .option], label: "Q")] {
            #expect(binding.validationError(for: .handsFree) == .reservedSystem)
            #expect(!settings.setShortcut(binding, for: .handsFree))
        }
        #expect(settings.shortcuts[.handsFree] == ShortcutAction.handsFree.defaultBinding)
        #expect(ShortcutBinding(keyCode: 49, modifiers: .command, label: "Space").validationError(for: .handsFree) == nil)
    }

    @Test("malformed persisted bindings fall back to defaults")
    func malformedStorage() {
        for value in ["not JSON", #"{"bindings":{"pushToTalk":{"keyCode":65535,"modifiers":1048576,"label":"K","doubleTap":false}}}"#] {
            let store = InMemoryKeyValueStore()
            store.set(value, forKey: DictationSettings.Keys.shortcuts)
            let settings = DictationSettings(store: store)
            #expect(settings.shortcuts == DictationShortcuts())
        }
    }
}
