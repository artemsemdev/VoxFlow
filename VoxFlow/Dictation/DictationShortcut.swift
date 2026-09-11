import AppKit

enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case pushToTalk, handsFree, cancel, reinsert

    var defaultBinding: ShortcutBinding {
        switch self {
        case .pushToTalk: ShortcutBinding(modifiers: .function)
        case .handsFree: ShortcutBinding(modifiers: .function, doubleTap: true)
        case .cancel: ShortcutBinding(keyCode: 53, label: "esc")
        case .reinsert: ShortcutBinding(keyCode: 9, modifiers: [.option, .command], label: "V")
        }
    }
}

enum ShortcutValidationError: Equatable { case modifierRequired, unsupportedKey, reservedSystem, invalidGesture }

/// Stores physical key identity separately from the recorder's display label.
struct ShortcutBinding: Codable, Equatable, Sendable {
    static let modifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command, .function]
    let keyCode: UInt16?
    let modifiers: UInt
    let label: String
    let doubleTap: Bool

    init(keyCode: UInt16? = nil, modifiers: NSEvent.ModifierFlags = [], label: String = "", doubleTap: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.modifierMask).rawValue
        self.label = switch keyCode {
        case 36: "Return"
        case 48: "Tab"
        case 49: "Space"
        case 51: "Delete"
        case 53: "esc"
        default: label.uppercased()
        }
        self.doubleTap = doubleTap
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var keycaps: [String] {
        let names: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"), (.function, "fn")]
        let keys = names.filter { flags.contains($0.0) }.map(\.1) + (keyCode == nil ? [] : [label])
        return doubleTap ? keys + keys : keys
    }

    func validationError(for action: ShortcutAction) -> ShortcutValidationError? {
        guard flags.subtracting(Self.modifierMask).isEmpty else { return .unsupportedKey }
        if doubleTap {
            return action == .handsFree && keyCode == nil && flags == .function ? nil : .invalidGesture
        }
        guard let keyCode else {
            return action == .pushToTalk && [.function, .option, .control].contains(flags) ? nil : .modifierRequired
        }
        // Modifier keycodes arrive as flagsChanged and must use the modifier-only representation.
        guard keyCode <= 126, !(54...63).contains(keyCode), !label.isEmpty else { return .unsupportedKey }
        if isReservedSystemChord { return .reservedSystem }
        if action == .cancel && keyCode == 53 && flags.isEmpty { return nil }
        return flags.intersection([.command, .control, .option, .function]).isEmpty ? .modifierRequired : nil
    }

    private var isReservedSystemChord: Bool {
        switch keyCode {
        case 48: flags == .command || flags == [.command, .shift] // Switch applications.
        case 53: flags == [.command, .option] || flags == [.command, .option, .shift] // Force quit.
        case 12: flags == [.command, .control] || flags == [.command, .shift]
            || flags == [.command, .shift, .option] // Lock / log out.
        default: false
        }
    }
}

struct DictationShortcuts: Codable, Equatable, Sendable {
    private var bindings: [String: ShortcutBinding] = [:]
    subscript(action: ShortcutAction) -> ShortcutBinding {
        get { bindings[action.rawValue] ?? action.defaultBinding }
        set { bindings[action.rawValue] = newValue }
    }
    func conflictingAction(with binding: ShortcutBinding, for action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { other in
            guard other != action else { return false }
            let candidate = self[other]
            return candidate.keyCode == binding.keyCode && candidate.flags == binding.flags && candidate.doubleTap == binding.doubleTap
        }
    }
    var isValid: Bool {
        ShortcutAction.allCases.allSatisfy { self[$0].validationError(for: $0) == nil && conflictingAction(with: self[$0], for: $0) == nil }
    }
}
