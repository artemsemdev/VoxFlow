import AppKit
import Testing
@testable import VoxFlow

@Suite("System shortcut conflicts") @MainActor
struct SystemShortcutConflictsTests {
    private let code = "kHISymbolicHotKeyCode"
    private let modifiers = "kHISymbolicHotKeyModifiers"
    private let enabled = "kHISymbolicHotKeyEnabled"

    @Test("enabled Carbon symbolic hotkeys report a generic macOS conflict")
    func enabledMatch() {
        let conflicts = provider([
            entry(keyCode: 49, carbonModifiers: (1 << 8) | (1 << 11), enabled: true)
        ])

        #expect(conflicts.name(for: ShortcutBinding(
            keyCode: 49, modifiers: [.command, .option], label: "Space")) == "macOS")
    }

    @Test("disabled, malformed, and nonmatching entries are ignored")
    func ignoredEntries() {
        let conflicts = provider([
            entry(keyCode: 49, carbonModifiers: 1 << 8, enabled: false),
            [enabled: true, code: NSNumber(value: 49)],
            entry(keyCode: 40, carbonModifiers: 1 << 8, enabled: true),
            entry(keyCode: 49, carbonModifiers: 1 << 9, enabled: true)
        ])

        #expect(conflicts.name(for: ShortcutBinding(
            keyCode: 49, modifiers: .command, label: "Space")) == nil)
    }

    @Test("Carbon modifier bits map to their AppKit meanings")
    func modifierMapping() {
        // Carbon's fn mask is bit 17; NSEvent's fn flag is bit 23.
        let conflicts = provider([
            entry(keyCode: 40, carbonModifiers: (1 << 8) | (1 << 9) | (1 << 11) | (1 << 12) | (1 << 17), enabled: true)
        ])

        #expect(conflicts.name(for: ShortcutBinding(
            keyCode: 40,
            modifiers: [.command, .shift, .option, .control, .function],
            label: "K")) == "macOS")
        // A Carbon command bit (1 << 8) must not be compared directly with NSEvent's raw flags.
        #expect(conflicts.name(for: ShortcutBinding(keyCode: 40, modifiers: .command, label: "K")) == nil)
    }

    @Test("unsupported Carbon modifiers and modifier-only bindings do not produce false conflicts")
    func unsupportedAndModifierOnly() {
        let conflicts = provider([
            entry(keyCode: 40, carbonModifiers: (1 << 8) | (1 << 10), enabled: true)
        ])

        #expect(conflicts.name(for: ShortcutBinding(keyCode: 40, modifiers: .command, label: "K")) == nil)
        #expect(conflicts.name(for: ShortcutBinding(modifiers: .function)) == nil)
        #expect(conflicts.name(for: ShortcutBinding(modifiers: .function, doubleTap: true)) == nil)
    }

    @Test("Fn-only gestures use the configured Fn action without reading Carbon hotkeys")
    func fnAction() {
        var carbonReads = 0
        let conflicts = SystemShortcutConflicts(
            snapshot: { carbonReads += 1; return [] },
            fnAction: { .emoji })

        #expect(conflicts.name(for: ShortcutBinding(modifiers: .function)) == "Show Emoji & Symbols")
        #expect(conflicts.name(for: ShortcutBinding(modifiers: .function, doubleTap: true)) == "Show Emoji & Symbols")
        #expect(carbonReads == 0)

        let disabled = SystemShortcutConflicts(
            snapshot: { carbonReads += 1; return [] },
            fnAction: { .doNothing })
        #expect(disabled.name(for: ShortcutBinding(modifiers: .function)) == nil)
        #expect(carbonReads == 0)
    }

    @Test("snapshot failure is treated as no known conflict")
    func snapshotFailure() {
        let conflicts = SystemShortcutConflicts(snapshot: { nil })
        #expect(conflicts.name(for: ShortcutBinding(keyCode: 40, modifiers: .command, label: "K")) == nil)
    }

    private func provider(_ entries: [NSDictionary]) -> SystemShortcutConflicts {
        SystemShortcutConflicts(snapshot: { entries }, fnAction: { .unknown })
    }

    private func entry(keyCode: UInt16, carbonModifiers: UInt32, enabled isEnabled: Bool) -> NSDictionary {
        [
            code: NSNumber(value: keyCode),
            modifiers: NSNumber(value: carbonModifiers),
            enabled: NSNumber(value: isEnabled)
        ]
    }
}
