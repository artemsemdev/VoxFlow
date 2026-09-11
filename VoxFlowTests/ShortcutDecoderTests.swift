import AppKit
import Testing
@testable import VoxFlow

@Suite("Shortcut event decoding")
struct ShortcutDecoderTests {
    func custom() -> DictationShortcuts {
        var bindings = DictationShortcuts()
        bindings[.pushToTalk] = ShortcutBinding(keyCode: 40, modifiers: [.control, .option], label: "K")
        bindings[.handsFree] = ShortcutBinding(keyCode: 49, modifiers: .option, label: "Space")
        bindings[.cancel] = ShortcutBinding(keyCode: 8, modifiers: .control, label: "C")
        return bindings
    }
    let active = ShortcutContext(hudActive: true)
    let handsFree = ShortcutContext(hudActive: true, handsFree: true)

    @Test("the default fn pair keeps press/release timing in the existing state machine")
    func defaults() {
        var decoder = ShortcutDecoder()
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged, flags: .function)) == [.fn(.down)])
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged, flags: [.function, .shift])).isEmpty)
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged, flags: [])).contains(.fn(.up)))
        #expect(decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 123, flags: .function)).isEmpty)
    }

    @Test("custom push-to-talk requires the exact chord and releases once even if modifiers go first")
    func chordEdges() {
        var decoder = ShortcutDecoder(shortcuts: custom())
        #expect(decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 40, flags: .option)).isEmpty)
        #expect(decoder.decode(ShortcutEvent(kind: .keyUp, keyCode: 40)).isEmpty)
        #expect(decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 40, flags: [.control, .option, .capsLock])) == [.pushToTalk(.down)])
        #expect(decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 40, flags: [.control, .option], isRepeat: true)).isEmpty)
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged, flags: .option)) == [.pushToTalk(.up)])
        #expect(decoder.decode(ShortcutEvent(kind: .keyUp, keyCode: 40)).isEmpty)
        #expect(decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 40, flags: [.control, .option, .shift])).isEmpty)
    }

    @Test("key-up releases push-to-talk without relying on its modifier snapshot")
    func keyUp() {
        var decoder = ShortcutDecoder(shortcuts: custom())
        _ = decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 40, flags: [.control, .option]))
        #expect(decoder.decode(ShortcutEvent(kind: .keyUp, keyCode: 40)) == [.pushToTalk(.up)])
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged)).isEmpty)
    }

    @Test("hands-free repeats are ignored and a new press toggles again")
    func handsFreeChord() {
        var decoder = ShortcutDecoder(shortcuts: custom())
        let down = ShortcutEvent(kind: .keyDown, keyCode: 49, flags: .option)
        #expect(decoder.decode(down) == [.handsFree])
        #expect(decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 49, flags: .option, isRepeat: true), context: handsFree).isEmpty)
        #expect(decoder.decode(ShortcutEvent(kind: .keyUp, keyCode: 49), context: handsFree).isEmpty)
        #expect(decoder.decode(down, context: handsFree) == [.handsFree])
    }

    @Test("custom cancel replaces esc, only acts with an active HUD, and reinsert works while idle")
    func secondaryActions() {
        var decoder = ShortcutDecoder(shortcuts: custom())
        #expect(decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 8, flags: .control)).isEmpty)
        #expect(decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 8, flags: .control), context: active) == [.cancel])
        #expect(decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 53), context: active) == [.anyKey])
        #expect(decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 9, flags: [.option, .command])) == [.reinsert])
        #expect(decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 0), context: active) == [.anyKey])
    }

    @Test("single Option push-to-talk aborts when it becomes a chord and cannot rearm during chord release")
    func modifierOnly() {
        var bindings = custom()
        bindings[.pushToTalk] = ShortcutBinding(modifiers: .option)
        var decoder = ShortcutDecoder(shortcuts: bindings)
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged, flags: .option)) == [.pushToTalk(.down)])
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged, flags: [.option, .command])) == [.cancel])
        #expect(decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 9, flags: [.option, .command])) == [.reinsert])
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged, flags: .option)).isEmpty)
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged)).isEmpty)
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged, flags: .option)) == [.pushToTalk(.down)])
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged)) == [.pushToTalk(.up)])
    }

    @Test("fn double tap still works after push-to-talk moves, while a held fn or interrupted tap does not")
    func independentDoubleTap() {
        var bindings = custom()
        bindings[.handsFree] = ShortcutAction.handsFree.defaultBinding
        var decoder = ShortcutDecoder(shortcuts: bindings)
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged, flags: .function, timestamp: 0)).isEmpty)
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged, timestamp: 0.1)).isEmpty)
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged, flags: .function, timestamp: 0.3)) == [.handsFree])
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged, timestamp: 0.4), context: handsFree).isEmpty)
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged, flags: .function, timestamp: 1), context: handsFree) == [.handsFree])
        _ = decoder.reset()
        _ = decoder.decode(ShortcutEvent(kind: .flagsChanged, flags: .function, timestamp: 2))
        _ = decoder.decode(ShortcutEvent(kind: .flagsChanged, timestamp: 3))
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged, flags: .function, timestamp: 3.1)).isEmpty)
        _ = decoder.decode(ShortcutEvent(kind: .flagsChanged, timestamp: 3.2))
        _ = decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 0, timestamp: 3.3))
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged, flags: .function, timestamp: 3.4)).isEmpty)
    }

    @Test("reset releases any held shortcut exactly once before replacing bindings or stopping monitoring")
    func reset() {
        var decoder = ShortcutDecoder(shortcuts: custom())
        _ = decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 40, flags: [.control, .option]))
        #expect(decoder.reset() == [.pushToTalk(.up)])
        #expect(decoder.reset().isEmpty)
        var legacy = ShortcutDecoder()
        _ = legacy.decode(ShortcutEvent(kind: .flagsChanged, flags: .function))
        #expect(legacy.reset() == [.fn(.up)])
        #expect(legacy.decode(ShortcutEvent(kind: .flagsChanged, flags: .function)) == [.fn(.down)])
    }

    @Test("Escape still cancels while the activation modifiers are held, including pending preflight")
    func cancelWhileHeld() {
        var legacy = ShortcutDecoder()
        _ = legacy.decode(ShortcutEvent(kind: .flagsChanged, flags: .function))
        #expect(legacy.decode(ShortcutEvent(kind: .keyDown, keyCode: 53, flags: .function), context: active) == [.cancel])
        var bindings = custom()
        bindings[.cancel] = ShortcutAction.cancel.defaultBinding
        var chord = ShortcutDecoder(shortcuts: bindings)
        _ = chord.decode(ShortcutEvent(kind: .keyDown, keyCode: 40, flags: [.control, .option]))
        #expect(chord.decode(ShortcutEvent(kind: .keyDown, keyCode: 53, flags: [.control, .option])) == [.cancel])
    }

    @Test("a modifier prefix of the hands-free stop chord cannot discard the hands-free capture")
    func sharedModifierStop() {
        var bindings = custom()
        bindings[.pushToTalk] = ShortcutBinding(modifiers: .option)
        var decoder = ShortcutDecoder(shortcuts: bindings)
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged, flags: .option), context: handsFree).isEmpty)
        #expect(decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 49, flags: .option), context: handsFree) == [.handsFree])
        #expect(decoder.decode(ShortcutEvent(kind: .flagsChanged), context: handsFree).isEmpty)
    }

    @Test("the synthetic function-key flag does not make Command-F1 require holding fn")
    func functionKeyFlag() {
        var bindings = custom()
        bindings[.handsFree] = ShortcutBinding(keyCode: 122, modifiers: .command, label: "F1")
        var decoder = ShortcutDecoder(shortcuts: bindings)
        #expect(decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 122, flags: [.command, .function])) == [.handsFree])
    }

    @Test("an explicitly assigned modified Escape chord starts and stops hands-free before broad Escape cancellation")
    func modifiedEscape() {
        var bindings = custom()
        bindings[.cancel] = ShortcutAction.cancel.defaultBinding
        bindings[.handsFree] = ShortcutBinding(keyCode: 53, modifiers: .option, label: "esc")
        #expect(bindings.isValid)
        var decoder = ShortcutDecoder(shortcuts: bindings)
        let chord = ShortcutEvent(kind: .keyDown, keyCode: 53, flags: .option)
        #expect(decoder.decode(chord) == [.handsFree])
        #expect(decoder.decode(chord, context: handsFree) == [.handsFree])
        #expect(decoder.decode(ShortcutEvent(kind: .keyDown, keyCode: 53), context: handsFree) == [.cancel])
    }
}
