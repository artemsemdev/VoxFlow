import SwiftUI

/// Menu bar dropdown, phase-0 subset of MB-01: status line, Open, Quit.
struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    /// Read directly off the shared composition root (as `VoxFlowApp`'s own command actions already
    /// do) — the `MenuBarExtra` scene doesn't otherwise inject `AppServices` via `.environment(_:)`.
    private var dictation: DictationCoordinator { AppServices.shared.dictation }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(Palette.onDevice).frame(width: 8, height: 8)
                Text(MenuBarStatus.text(for: dictation.state))
            }
            Text(dictation.hotkeyMode == .handsFree ? "Hotkey: Double-tap fn" : "Hotkey: Hold fn")
                .foregroundStyle(.secondary)
        }
        Divider()
        Button("Open VoxFlow") { openWindow(id: MainWindowID.main) }
        Divider()
        Button("Quit VoxFlow") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

enum MainWindowID {
    static let main = "main"
}
