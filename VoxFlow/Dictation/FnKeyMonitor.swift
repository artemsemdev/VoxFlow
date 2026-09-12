import AppKit
@preconcurrency import CoreGraphics

/// `true` means the source must suppress the event instead of forwarding it to the focused app.
@MainActor
protocol ShortcutEventSource: AnyObject {
    var isRunning: Bool { get }
    func start(handler: @escaping (ShortcutEvent) -> Bool, onLoss: @escaping () -> Void)
    func stop()
}

/// A session event tap sees both VoxFlow and other applications exactly once and can consume an
/// owned chord. `NSEvent` global monitors cannot consume events, so there is no AppKit fallback.
@MainActor
private final class CGEventTapShortcutEventSource: ShortcutEventSource {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: ((ShortcutEvent) -> Bool)?
    private var onLoss: (() -> Void)?

    var isRunning: Bool {
        guard let tap else { return false }
        return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
    }

    func start(handler: @escaping (ShortcutEvent) -> Bool, onLoss: @escaping () -> Void) {
        guard !isRunning else { return }
        stop() // A disabled/invalid port must not prevent creation after permission is restored.
        self.handler = handler
        self.onLoss = onLoss
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            self.handler = nil
            self.onLoss = nil
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        runLoopSource = nil
        handler = nil
        onLoss = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let source = Unmanaged<CGEventTapShortcutEventSource>.fromOpaque(context).takeUnretainedValue()
        // The tap is installed on `CFRunLoopGetMain()` and removed before `source` can deallocate,
        // so Core Graphics invokes this callback on the main actor for the source's full lifetime.
        return MainActor.assumeIsolated { source.receive(type: type, event: event) }
    }

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            onLoss?()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let kind: ShortcutEvent.Kind
        switch type {
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: return Unmanaged.passUnretained(event)
        }
        let snapshot = ShortcutEvent(
            kind: kind,
            keyCode: kind == .flagsChanged ? nil : UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)),
            timestamp: TimeInterval(event.timestamp) / 1_000_000_000,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        return handler?(snapshot) == true ? nil : Unmanaged.passUnretained(event)
    }
}

/// Decodes live bindings and routes commands. Tests inject a fake source and never install an event
/// tap or request Accessibility access.
@MainActor
final class FnKeyMonitor {
    private var decoder: ShortcutDecoder
    private var bindings: DictationShortcuts
    private var ownedKeyCodes: Set<UInt16> = []
    private var wantsMonitoring = false
    private let source: any ShortcutEventSource
    private let shortcuts: () -> DictationShortcuts
    private let context: () -> ShortcutContext
    private let suspended: () -> Bool
    private let onFn: (FnTransition) -> Void
    private let onPush: (FnTransition) -> Void
    private let onHandsFree: () -> Void
    private let onEscape: () -> Void
    private let onReinsert: (() -> Void)?
    private let onAnyKey: () -> Void

    init(
        onFn: @escaping (FnTransition) -> Void,
        onEscape: @escaping () -> Void,
        onAnyKey: @escaping () -> Void,
        isHUDActive: @escaping () -> Bool,
        source: any ShortcutEventSource = CGEventTapShortcutEventSource(),
        shortcuts: @escaping () -> DictationShortcuts = { DictationShortcuts() },
        context: (() -> ShortcutContext)? = nil,
        suspended: @escaping () -> Bool = { false },
        onPush: @escaping (FnTransition) -> Void = { _ in },
        onHandsFree: @escaping () -> Void = {},
        onReinsert: (() -> Void)? = nil
    ) {
        let initial = shortcuts()
        self.source = source
        self.shortcuts = shortcuts
        self.bindings = initial
        self.decoder = ShortcutDecoder(shortcuts: initial)
        self.context = context ?? { ShortcutContext(hudActive: isHUDActive()) }
        self.suspended = suspended
        self.onFn = onFn
        self.onPush = onPush
        self.onHandsFree = onHandsFree
        self.onEscape = onEscape
        self.onReinsert = onReinsert
        self.onAnyKey = onAnyKey
    }

    func start() {
        wantsMonitoring = true
        refreshEventSource()
    }

    /// Recheck after returning from System Settings. Healthy taps retain their current gesture;
    /// failed creation or a revoked/disabled tap can recover without restarting the application.
    func refreshEventSource() {
        guard wantsMonitoring, !source.isRunning else { return }
        reset()
        ownedKeyCodes.removeAll() // Key-up may have been missed while the old tap was unavailable.
        source.start(
            handler: { [weak self] in self?.receive($0) ?? false },
            onLoss: { [weak self] in self?.eventSourceLost() })
    }

    func stop() {
        wantsMonitoring = false
        reset()
        source.stop()
        ownedKeyCodes.removeAll()
    }
    func eventSourceLost() { reset() }
    func configurationDidChange() { synchronizeBindings() }
    func suspensionDidChange() { if suspended() { reset() } }

    private func receive(_ event: ShortcutEvent) -> Bool {
        let physicallyOwned = event.keyCode.map(ownedKeyCodes.contains) ?? false
        if suspended() {
            reset()
            if event.kind == .keyUp, let keyCode = event.keyCode { ownedKeyCodes.remove(keyCode) }
            return physicallyOwned && (event.kind == .keyDown || event.kind == .keyUp)
        }
        synchronizeBindings()

        let commands = decoder.decode(event, context: context())
        commands.forEach(route)
        guard event.kind == .keyDown || event.kind == .keyUp else { return false }
        if physicallyOwned {
            if event.kind == .keyUp, let keyCode = event.keyCode { ownedKeyCodes.remove(keyCode) }
            return true
        }
        if event.kind == .keyDown, ownsKeyEvent(event, commands: commands), let keyCode = event.keyCode {
            ownedKeyCodes.insert(keyCode)
            return true
        }
        return false
    }

    private func synchronizeBindings() {
        let current = shortcuts()
        guard current != bindings else { return }
        reset()
        bindings = current
        decoder = ShortcutDecoder(shortcuts: current)
    }

    private func ownsKeyEvent(_ event: ShortcutEvent, commands: [ShortcutCommand]) -> Bool {
        let flags = event.flags.intersection(ShortcutBinding.modifierMask)
        let exactAction = ShortcutAction.allCases.first {
            let binding = bindings[$0]
            return binding.keyCode == event.keyCode && binding.flags == flags
        }
        if let exactAction {
            return switch exactAction {
            case .pushToTalk: commands.contains(.pushToTalk(.down))
            case .handsFree: commands.contains(.handsFree)
            case .cancel: commands.contains(.cancel)
            case .reinsert: onReinsert != nil && commands.contains(.reinsert)
            }
        }
        // Escape may carry the modifiers of a held PTT chord. The decoder recognizes that as the
        // configured cancel gesture; an unrelated key that merely aborts modifier-only PTT passes.
        return event.keyCode == bindings[.cancel].keyCode && commands.contains(.cancel)
    }

    private func reset() {
        decoder.reset().forEach(route)
    }

    private func route(_ command: ShortcutCommand) {
        switch command {
        case .fn(let transition): onFn(transition)
        case .pushToTalk(let transition): onPush(transition)
        case .handsFree: onHandsFree()
        case .cancel: onEscape()
        case .reinsert: onReinsert?()
        case .anyKey: onAnyKey()
        }
    }
}
