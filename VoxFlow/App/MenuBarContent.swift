import SwiftUI

/// Menu bar dropdown, phase-0 subset of MB-01: status line, Open, Quit.
struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Palette.onDevice).frame(width: 8, height: 8)
            Text("Ready · on-device")
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
