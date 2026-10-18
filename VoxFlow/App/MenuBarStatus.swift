import SwiftUI
import VoxFlowDictation

/// Pure state → menu bar text/colour mappings (design MB-01). No view holds this logic itself.
enum MenuBarStatus {
    static func text(for state: FlowBarState) -> String {
        switch state {
        case .listening: "Listening…"
        case .processing: "Cleaning up…"
        // MB-02: the specific "Paused until 10:41" wall-clock text needs a `Date` this pure,
        // state-only function doesn't have — `MenuBarViewModel.statusText` builds that string
        // (via `pausedUntilText`) and falls back to this plain word only when it can't.
        case .paused: "Paused"
        default: "Ready · on-device"
        }
    }

    /// M-7: pairs the status dot's colour with `text(for:)` — canvas MB-01 shows red while listening
    /// and amber while processing, not the dot always sitting on the green "on-device" colour.
    /// MB-02: amber while paused too.
    static func dotColor(for state: FlowBarState) -> Color {
        switch state {
        case .listening: Palette.recording
        case .processing, .paused: Palette.amber
        default: Palette.onDevice
        }
    }

    static func hotkeyLine(for mode: HotkeyMode) -> String {
        mode == .handsFree ? "Hotkey: Double-tap fn" : "Hotkey: Hold fn"
    }
}
