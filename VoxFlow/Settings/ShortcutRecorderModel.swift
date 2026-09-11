import AppKit
import Observation

@Observable @MainActor
final class ShortcutRecorderModel {
    enum Conflict: Equatable {
        case action(ShortcutAction), system(String), invalid(ShortcutValidationError)
    }

    private(set) var action: ShortcutAction?
    private(set) var candidate: ShortcutBinding?
    private(set) var conflict: Conflict?
    private(set) var focusGeneration: UInt64 = 0
    var isRecording: Bool { action != nil }
    var onRecordingChange: (() -> Void)?
    private let settings: DictationSettings
    private let systemConflict: (ShortcutBinding) -> String?
    private var heldModifiers: NSEvent.ModifierFlags = []

    init(settings: DictationSettings, systemConflict: @escaping (ShortcutBinding) -> String? = { _ in nil }) {
        self.settings = settings
        self.systemConflict = systemConflict
    }

    func begin(_ action: ShortcutAction) {
        self.action = action
        chooseAnother()
        onRecordingChange?()
    }

    func cancel() {
        guard isRecording else { return }
        action = nil
        chooseAnother()
        onRecordingChange?()
    }

    func chooseAnother() {
        candidate = nil
        conflict = nil
        heldModifiers = []
        focusGeneration &+= 1
    }

    func useDefault() {
        guard let action else { return }
        consider(action.defaultBinding)
    }

    func useAnyway() {
        guard case .system = conflict, let candidate else { return }
        // Revalidate internal bindings in case settings changed while the conflict was displayed.
        consider(candidate, allowSystemConflict: true)
    }

    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        guard isRecording, conflict == nil else { return }
        let flags = flags.intersection(ShortcutBinding.modifierMask)
        if !flags.isEmpty {
            heldModifiers.formUnion(flags)
            candidate = ShortcutBinding(modifiers: flags)
        } else if !heldModifiers.isEmpty {
            let binding = ShortcutBinding(modifiers: heldModifiers)
            heldModifiers = []
            consider(binding)
        }
    }

    func keyDown(code: UInt16, flags: NSEvent.ModifierFlags, label: String, isRepeat: Bool = false) {
        guard isRecording, !isRepeat else { return }
        if code == 53, flags.intersection(ShortcutBinding.modifierMask).isEmpty {
            cancel()
            return
        }
        if code == 36, flags.intersection(ShortcutBinding.modifierMask).isEmpty, conflict != nil {
            chooseAnother()
            return
        }
        guard conflict == nil else { return }
        var flags = flags
        // AppKit marks arrows/F-keys with .function even without physical fn being held.
        if !heldModifiers.contains(.function) { flags.remove(.function) }
        consider(ShortcutBinding(keyCode: code, modifiers: flags, label: label))
    }

    private func consider(_ binding: ShortcutBinding, allowSystemConflict: Bool = false) {
        guard let action else { return }
        candidate = binding
        if let error = binding.validationError(for: action) { conflict = .invalid(error) }
        else if let other = settings.shortcuts.conflictingAction(with: binding, for: action) { conflict = .action(other) }
        else if !allowSystemConflict, let name = systemConflict(binding) { conflict = .system(name) }
        else if settings.setShortcut(binding, for: action) { cancel() }
    }
}

extension ShortcutAction {
    var title: String {
        switch self {
        case .pushToTalk: "Push-to-talk"
        case .handsFree: "Hands-free"
        case .cancel: "Cancel"
        case .reinsert: "Re-insert last dictation"
        }
    }
    var subtitle: String {
        switch self {
        case .pushToTalk: "Hold to dictate, release to insert"
        case .handsFree: "Press to start, press again to stop"
        case .cancel: "Discard the current dictation"
        case .reinsert: "Useful when the wrong field had focus"
        }
    }
}

extension ShortcutRecorderModel {
    var defaultTitle: String { "Use \(action?.defaultBinding.keycaps.joined(separator: " ") ?? "default") (default)" }
    var conflictTitle: String {
        let keys = candidate?.keycaps.joined(separator: " ") ?? "This shortcut"
        switch conflict {
        case .action(let action): return "\(keys) is used by \(action.title)."
        case .system(let name): return "\(keys) is used by \(name)."
        case .invalid(.reservedSystem): return "macOS reserves this shortcut."
        case .invalid: return "Choose a supported shortcut."
        case nil: return ""
        }
    }
    var instructions: String {
        switch conflict {
        case .system(let name):
            return "Both would fire. Choose another combination, or keep it and disable the \(name) shortcut in System Settings → Keyboard."
        case .action:
            return "Each VoxFlow action needs its own shortcut. Choose another combination, or change the other action first."
        case .invalid(.reservedSystem):
            return "Choose another combination. This shortcut cannot be replaced."
        case .invalid:
            return "Include ⌘, ⌥, ⌃ or fn with a key. Push-to-talk also supports a single fn, ⌥ or ⌃."
        case nil:
            return action == .pushToTalk
                ? "Press the keys you want to hold. Single modifier keys (fn, ⌥, ⌃) work best for push-to-talk."
                : "Press your shortcut. Include ⌘, ⌥, ⌃ or fn with a key."
        }
    }
}
