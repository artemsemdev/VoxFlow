import AppKit
import VoxFlowDictation

struct ShortcutEvent {
    enum Kind { case flagsChanged, keyDown, keyUp }
    var kind: Kind
    var keyCode: UInt16? = nil
    var flags: NSEvent.ModifierFlags = []
    var timestamp: TimeInterval = 0
    var isRepeat = false
}

struct ShortcutContext {
    var hudActive = false
    var handsFree = false
}

enum ShortcutCommand: Equatable, Sendable {
    case fn(FnTransition), pushToTalk(FnTransition), handsFree, cancel, reinsert, anyKey
}

/// Pure keyboard decoder. The monitor supplies event snapshots; tests never install OS monitors.
struct ShortcutDecoder {
    let shortcuts: DictationShortcuts
    private let config: FlowBarConfig
    private var fn = FnKeyDecoder()
    private var previousFlags: NSEvent.ModifierFlags = []
    private var heldPushToTalk: ShortcutBinding?
    private var fnDownAt: TimeInterval?
    private var fnTapAt: TimeInterval?
    private var fnTriggered = false

    init(shortcuts: DictationShortcuts = DictationShortcuts(), config: FlowBarConfig = FlowBarConfig()) {
        self.shortcuts = shortcuts
        self.config = config
    }

    private var sharedFn: Bool {
        let push = shortcuts[.pushToTalk], free = shortcuts[.handsFree]
        return push.keyCode == nil && push.flags == .function && free.keyCode == nil && free.flags == .function && free.doubleTap
    }

    mutating func decode(_ event: ShortcutEvent, context: ShortcutContext = ShortcutContext()) -> [ShortcutCommand] {
        var flags = event.flags.intersection(ShortcutBinding.modifierMask)
        // AppKit also marks F-keys/arrows with .function. Only flagsChanged establishes that
        // the physical fn modifier is held; synthetic key flags must not alter a saved chord.
        if event.kind != .flagsChanged && !previousFlags.contains(.function) { flags.remove(.function) }
        defer { if event.kind == .flagsChanged { previousFlags = flags } }
        if sharedFn, event.kind == .flagsChanged {
            return fn.decode(flags: flags).map { [.fn($0)] } ?? []
        }
        var commands: [ShortcutCommand] = []
        if context.handsFree { heldPushToTalk = nil }
        let activationFlags = heldPushToTalk?.flags ?? (sharedFn && previousFlags.contains(.function) ? .function : [])
        let canCancel = context.hudActive || !activationFlags.isEmpty
        if let held = heldPushToTalk {
            if event.kind == .keyUp, event.keyCode == held.keyCode {
                heldPushToTalk = nil
                commands.append(.pushToTalk(.up))
            } else if event.kind == .flagsChanged, !flags.isSuperset(of: held.flags) {
                heldPushToTalk = nil
                commands.append(.pushToTalk(.up))
            } else if held.keyCode == nil && (event.kind == .keyDown || flags != held.flags) {
                // Option/Control must still work as prefixes of ordinary shortcuts. Abort that
                // modifier-only capture before handling the completed chord, without inserting it.
                heldPushToTalk = nil
                commands.append(.cancel)
            }
        }
        if !sharedFn, shortcuts[.handsFree].doubleTap {
            commands += decodeDoubleFn(event, flags: flags, context: context)
        }
        let push = shortcuts[.pushToTalk]
        if !context.handsFree, event.kind == .flagsChanged, push.keyCode == nil, flags == push.flags,
           !previousFlags.isSuperset(of: push.flags), heldPushToTalk == nil {
            heldPushToTalk = push
            commands.append(.pushToTalk(.down))
        }
        guard event.kind == .keyDown, !event.isRepeat else { return commands }
        let exactAction = ShortcutAction.allCases.first {
            shortcuts[$0].keyCode == event.keyCode && shortcuts[$0].flags == flags
        }
        for action in [ShortcutAction.cancel, .handsFree, .reinsert, .pushToTalk] {
            let binding = shortcuts[action]
            guard let key = binding.keyCode, key == event.keyCode else { continue }
            let cancelWithHeldModifiers = action == .cancel && exactAction == nil &&
                (flags == binding.flags.union(activationFlags) || (key == 53 && binding.flags.isEmpty))
            guard binding.flags == flags || cancelWithHeldModifiers else { continue }
            switch action {
            case .cancel:
                if canCancel && !commands.contains(.cancel) { heldPushToTalk = nil; commands.append(.cancel) }
            case .handsFree: commands.append(.handsFree)
            case .reinsert: commands.append(.reinsert)
            case .pushToTalk:
                if !context.handsFree && heldPushToTalk == nil { heldPushToTalk = binding; commands.append(.pushToTalk(.down)) }
            }
            return commands
        }
        if commands.isEmpty && context.hudActive { commands.append(.anyKey) }
        return commands
    }

    private mutating func decodeDoubleFn(_ event: ShortcutEvent, flags: NSEvent.ModifierFlags,
                                         context: ShortcutContext) -> [ShortcutCommand] {
        if event.kind == .keyDown || !flags.subtracting(.function).isEmpty {
            fnTapAt = nil
            fnDownAt = nil
        }
        guard event.kind == .flagsChanged, let edge = fn.decode(flags: flags) else { return [] }
        switch edge {
        case .down:
            fnDownAt = flags == .function ? event.timestamp : nil
            fnTriggered = false
            let gap = fnTapAt.map { event.timestamp - $0 }
            fnTapAt = nil
            if flags == .function, context.handsFree || gap.map({ $0 >= 0 && $0 <= config.doubleTapWindow }) == true {
                fnTriggered = true
                return [.handsFree]
            }
        case .up:
            let duration = fnDownAt.map { event.timestamp - $0 }
            fnTapAt = !fnTriggered && !context.handsFree && duration.map({ $0 >= 0 && $0 < config.holdThreshold }) == true ? event.timestamp : nil
            fnDownAt = nil
        }
        return []
    }

    mutating func reset() -> [ShortcutCommand] {
        let releases: [ShortcutCommand] = heldPushToTalk != nil ? [.pushToTalk(.up)]
            : sharedFn && previousFlags.contains(.function) ? [.fn(.up)] : []
        self = ShortcutDecoder(shortcuts: shortcuts, config: config)
        return releases
    }
}
