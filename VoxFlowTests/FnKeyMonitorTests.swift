import AppKit
import Testing
@testable import VoxFlow

@MainActor
struct FnKeyMonitorTests {
    final class Source: ShortcutEventSource {
        private var handler: ((ShortcutEvent) -> Bool)?
        private var onLoss: (() -> Void)?
        var allowsStart = true
        private(set) var isRunning = false
        private(set) var startAttempts = 0

        func start(handler: @escaping (ShortcutEvent) -> Bool, onLoss: @escaping () -> Void) {
            guard !isRunning else { return }
            startAttempts += 1
            guard allowsStart else { return }
            self.handler = handler
            self.onLoss = onLoss
            isRunning = true
        }
        func stop() { handler = nil; onLoss = nil; isRunning = false }
        func send(_ event: ShortcutEvent) -> Bool { handler?(event) ?? false }
        func loseTap() { onLoss?() }
    }

    final class LiveState {
        var shortcuts: DictationShortcuts
        var context = ShortcutContext()
        var suspended = false
        init(shortcuts: DictationShortcuts) { self.shortcuts = shortcuts }
    }

    private func bindings(keyCode: UInt16 = 40) -> DictationShortcuts {
        var value = DictationShortcuts()
        value[.pushToTalk] = ShortcutBinding(
            keyCode: keyCode, modifiers: [.control, .option], label: "K")
        value[.handsFree] = ShortcutBinding(
            keyCode: 49, modifiers: .option, label: "Space")
        return value
    }

    @Test("explicit chords own down, repeats, and up while unmatched events pass through")
    func explicitChordConsumption() {
        let source = Source()
        let state = LiveState(shortcuts: bindings())
        var calls: [String] = []
        let monitor = makeMonitor(source: source, state: state) { calls.append($0) }
        monitor.start()

        #expect(!source.send(key(.keyDown, 40, [.control])))
        #expect(source.send(key(.keyDown, 40, [.control, .option])))
        #expect(source.send(key(.keyDown, 40, [.control, .option], repeat: true)))
        #expect(source.send(key(.keyUp, 40)))
        #expect(!source.send(key(.keyUp, 40)))
        #expect(calls == ["pushDown", "pushUp"])
    }

    @Test("cancel during key-based PTT preserves both suppressed key-up obligations")
    func overlappingOwnedKeys() {
        let source = Source()
        let state = LiveState(shortcuts: bindings())
        state.context.hudActive = true
        var calls: [String] = []
        let monitor = makeMonitor(source: source, state: state) { calls.append($0) }
        monitor.start()

        #expect(source.send(key(.keyDown, 40, [.control, .option])))
        #expect(source.send(key(.keyDown, 53, [.control, .option])))
        #expect(source.send(key(.keyUp, 53)))
        #expect(source.send(key(.keyUp, 40)))
        #expect(calls == ["pushDown", "escape"])
    }

    @Test("reinsert passes through when its production adapter is absent")
    func unavailableReinsertPassesThrough() {
        let source = Source()
        let state = LiveState(shortcuts: bindings())
        let monitor = FnKeyMonitor(
            onFn: { _ in }, onEscape: {}, onAnyKey: {}, isHUDActive: { false },
            source: source, shortcuts: { state.shortcuts }, context: { state.context })
        monitor.start()

        #expect(!source.send(key(.keyDown, 9, [.option, .command])))
        #expect(!source.send(key(.keyUp, 9)))
    }

    @Test("an ordinary chord that aborts modifier-only PTT remains pass-through")
    func modifierOnlyAbortPassesThrough() {
        let source = Source()
        var shortcuts = DictationShortcuts()
        shortcuts[.pushToTalk] = ShortcutBinding(modifiers: .option)
        let state = LiveState(shortcuts: shortcuts)
        var calls: [String] = []
        let monitor = makeMonitor(source: source, state: state) { calls.append($0) }
        monitor.start()

        #expect(!source.send(flags(.option, at: 1)))
        #expect(!source.send(key(.keyDown, 7, [.option])))
        #expect(calls == ["pushDown", "escape"])
    }

    @Test("hands-free and reinsert route once and consume their complete key gestures")
    func commandRouting() {
        let source = Source()
        let state = LiveState(shortcuts: bindings())
        var calls: [String] = []
        let monitor = makeMonitor(source: source, state: state) { calls.append($0) }
        monitor.start()

        #expect(source.send(key(.keyDown, 49, [.option])))
        #expect(source.send(key(.keyUp, 49)))
        #expect(source.send(key(.keyDown, 9, [.option, .command])))
        #expect(source.send(key(.keyUp, 9)))
        #expect(calls == ["handsFree", "reinsert"])
    }

    @Test("cancel is owned only with an active HUD; other active-HUD keys remain pass-through")
    func contextualCancelAndAnyKey() {
        let source = Source()
        let state = LiveState(shortcuts: bindings())
        var calls: [String] = []
        let monitor = makeMonitor(source: source, state: state) { calls.append($0) }
        monitor.start()

        #expect(!source.send(key(.keyDown, 53)))
        #expect(calls.isEmpty)
        state.context.hudActive = true
        #expect(!source.send(key(.keyDown, 0)))
        #expect(source.send(key(.keyDown, 53)))
        #expect(source.send(key(.keyDown, 53, repeat: true)))
        #expect(source.send(key(.keyUp, 53)))
        #expect(calls == ["any", "escape"])
    }

    @Test("default fn remains pass-through and preserves legacy transitions")
    func legacyFn() {
        let source = Source()
        let state = LiveState(shortcuts: DictationShortcuts())
        var calls: [String] = []
        let monitor = makeMonitor(source: source, state: state) { calls.append($0) }
        monitor.start()

        #expect(!source.send(flags(.function, at: 1)))
        #expect(!source.send(flags([], at: 1.5)))
        #expect(calls == ["fnDown", "fnUp"])
    }

    @Test("live reconfiguration releases an owned hold before recognizing the new binding")
    func liveReconfiguration() {
        let source = Source()
        let state = LiveState(shortcuts: bindings())
        var calls: [String] = []
        let monitor = makeMonitor(source: source, state: state) { calls.append($0) }
        monitor.start()

        #expect(source.send(key(.keyDown, 40, [.control, .option])))
        state.shortcuts = bindings(keyCode: 41)
        monitor.configurationDidChange()
        #expect(calls == ["pushDown", "pushUp"])
        #expect(source.send(key(.keyUp, 40)))
        #expect(source.send(key(.keyDown, 41, [.control, .option])))
        #expect(calls == ["pushDown", "pushUp", "pushDown"])
    }

    @Test("recorder suspension and event-tap loss release held input immediately")
    func resetHeldInput() {
        let source = Source()
        let state = LiveState(shortcuts: bindings())
        var calls: [String] = []
        let monitor = makeMonitor(source: source, state: state) { calls.append($0) }
        monitor.start()

        #expect(source.send(key(.keyDown, 40, [.control, .option])))
        state.suspended = true
        monitor.suspensionDidChange()
        #expect(calls == ["pushDown", "pushUp"])
        #expect(source.send(key(.keyUp, 40)))
        #expect(!source.send(key(.keyDown, 41, [.control, .option])))
        state.suspended = false
        #expect(source.send(key(.keyDown, 40, [.control, .option])))
        source.loseTap()
        #expect(calls == ["pushDown", "pushUp", "pushDown", "pushUp"])
        #expect(source.send(key(.keyUp, 40)))
        #expect(!source.send(key(.keyUp, 40)))
    }

    @Test("a failed first tap starts on permission recheck and delivers the next Fn gesture")
    func initialFailureRecovers() {
        let source = Source()
        source.allowsStart = false
        let state = LiveState(shortcuts: DictationShortcuts())
        var calls: [String] = []
        let monitor = makeMonitor(source: source, state: state) { calls.append($0) }
        monitor.start()
        #expect(!source.isRunning && source.startAttempts == 1)
        #expect(!source.send(flags(.function, at: 1)))
        #expect(calls.isEmpty)

        source.allowsStart = true
        monitor.refreshEventSource()
        #expect(source.isRunning && source.startAttempts == 2)
        #expect(!source.send(flags(.function, at: 2)))
        #expect(!source.send(flags([], at: 2.5)))
        #expect(calls == ["fnDown", "fnUp"])
    }

    @Test("repeated activation keeps a healthy tap and a held gesture intact")
    func healthyRefreshIsIdempotent() {
        let source = Source()
        let state = LiveState(shortcuts: DictationShortcuts())
        var calls: [String] = []
        let monitor = makeMonitor(source: source, state: state) { calls.append($0) }
        monitor.start()
        #expect(!source.send(flags(.function, at: 1)))
        monitor.start()
        monitor.refreshEventSource()
        #expect(source.startAttempts == 1 && calls == ["fnDown"])
        #expect(!source.send(flags([], at: 1.5)))
        #expect(calls == ["fnDown", "fnUp"])
    }

    @Test("a lost source resets its held gesture and is recreated on activation")
    func unavailableSourceRecovers() {
        let source = Source()
        let state = LiveState(shortcuts: DictationShortcuts())
        var calls: [String] = []
        let monitor = makeMonitor(source: source, state: state) { calls.append($0) }
        monitor.start()
        #expect(!source.send(flags(.function, at: 1)))
        source.stop()
        monitor.refreshEventSource()
        #expect(source.isRunning && source.startAttempts == 2)
        #expect(calls == ["fnDown", "fnUp"])
        #expect(!source.send(flags(.function, at: 2)))
        #expect(calls == ["fnDown", "fnUp", "fnDown"])
    }

    @Test("a dead tap cannot retain key ownership after its key-up was missed")
    func lostKeyUpDoesNotSwallowTyping() {
        let source = Source()
        let state = LiveState(shortcuts: bindings())
        let monitor = makeMonitor(source: source, state: state) { _ in }
        monitor.start()
        #expect(source.send(key(.keyDown, 40, [.control, .option])))
        source.stop() // The chord's key-up occurred while the source could not receive it.
        monitor.refreshEventSource()
        #expect(!source.send(key(.keyDown, 40)))
        #expect(!source.send(key(.keyUp, 40)))
        #expect(source.send(key(.keyDown, 40, [.control, .option])))
        #expect(source.send(key(.keyUp, 40)))
    }

    @Test("an explicit stop prevents a later activation from resurrecting the failed tap")
    func stoppedMonitorStaysStopped() {
        let source = Source()
        source.allowsStart = false
        let state = LiveState(shortcuts: DictationShortcuts())
        let monitor = makeMonitor(source: source, state: state) { _ in }
        monitor.start()
        monitor.stop()
        source.allowsStart = true
        monitor.refreshEventSource()
        #expect(!source.isRunning && source.startAttempts == 1)
        monitor.start()
        #expect(source.isRunning && source.startAttempts == 2)
    }

    private func makeMonitor(source: Source, state: LiveState,
                             record: @escaping (String) -> Void) -> FnKeyMonitor {
        FnKeyMonitor(
            onFn: { record($0 == .down ? "fnDown" : "fnUp") },
            onEscape: { record("escape") },
            onAnyKey: { record("any") },
            isHUDActive: { state.context.hudActive },
            source: source,
            shortcuts: { state.shortcuts },
            context: { state.context },
            suspended: { state.suspended },
            onPush: { record($0 == .down ? "pushDown" : "pushUp") },
            onHandsFree: { record("handsFree") },
            onReinsert: { record("reinsert") })
    }

    private func key(_ kind: ShortcutEvent.Kind, _ code: UInt16,
                     _ flags: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false) -> ShortcutEvent {
        ShortcutEvent(kind: kind, keyCode: code, flags: flags, isRepeat: isRepeat)
    }

    private func flags(_ flags: NSEvent.ModifierFlags, at timestamp: TimeInterval) -> ShortcutEvent {
        ShortcutEvent(kind: .flagsChanged, flags: flags, timestamp: timestamp)
    }
}
