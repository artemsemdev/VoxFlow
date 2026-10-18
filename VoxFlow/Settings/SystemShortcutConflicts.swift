import AppKit
import Carbon.HIToolbox

/// Looks up key-based shortcuts currently reserved by macOS.
@MainActor
struct SystemShortcutConflicts {
    typealias Snapshot = () -> [NSDictionary]?

    private static let codeKey = "kHISymbolicHotKeyCode"
    private static let modifiersKey = "kHISymbolicHotKeyModifiers"
    private static let enabledKey = "kHISymbolicHotKeyEnabled"
    private let snapshot: Snapshot
    private let fnAction: () -> FnSystemAction

    init(snapshot: @escaping Snapshot = { copySnapshot() },
         fnAction: @escaping () -> FnSystemAction = { FnSystemAction.current() }) {
        self.snapshot = snapshot
        self.fnAction = fnAction
    }

    func name(for binding: ShortcutBinding) -> String? {
        if binding.keyCode == nil, binding.flags == .function { return fnAction().conflictName }
        guard let keyCode = binding.keyCode, let entries = snapshot() else { return nil }
        let flags = binding.flags.intersection(ShortcutBinding.modifierMask)
        let matches = entries.contains { entry in
            guard (entry[Self.enabledKey] as? Bool) == true,
                  let code = entry[Self.codeKey] as? NSNumber,
                  let modifiers = entry[Self.modifiersKey] as? NSNumber,
                  code.int64Value >= 0, code.int64Value <= Int64(UInt16.max),
                  let systemFlags = Self.appKitFlags(from: modifiers.uint32Value) else { return false }
            return UInt16(code.int64Value) == keyCode && systemFlags == flags
        }
        // CopySymbolicHotKeys intentionally exposes no stable action identifier or display name.
        return matches ? "macOS" : nil
    }

    private static func copySnapshot() -> [NSDictionary]? {
        var result: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&result) == noErr, let result else { return nil }
        return (result.takeRetainedValue() as NSArray).compactMap { $0 as? NSDictionary }
    }

    private static func appKitFlags(from carbonFlags: UInt32) -> NSEvent.ModifierFlags? {
        let commandMask = UInt32(cmdKey)
        let shiftMask = UInt32(shiftKey | rightShiftKey)
        let optionMask = UInt32(optionKey | rightOptionKey)
        let controlMask = UInt32(controlKey | rightControlKey)
        let functionMask = UInt32(kEventKeyModifierFnMask)
        let supportedMask = commandMask | shiftMask | optionMask | controlMask | functionMask
        guard carbonFlags & ~supportedMask == 0 else { return nil }

        var result: NSEvent.ModifierFlags = []
        if carbonFlags & commandMask != 0 { result.insert(.command) }
        if carbonFlags & shiftMask != 0 { result.insert(.shift) }
        if carbonFlags & optionMask != 0 { result.insert(.option) }
        if carbonFlags & controlMask != 0 { result.insert(.control) }
        if carbonFlags & functionMask != 0 { result.insert(.function) }
        return result
    }
}
