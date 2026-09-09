import SwiftUI
import VoxFlowDictation

/// Pure state → menu bar text/colour mappings (design MB-01). No view holds this logic itself.
enum MenuBarStatus {
    static func text(for state: FlowBarState) -> String {
        switch state {
        case .listening: "Listening…"
        case .processing: "Cleaning up…"
        default: "Ready · on-device"
        }
    }

    /// M-7: pairs the status dot's colour with `text(for:)` — canvas MB-01 shows red while listening
    /// and amber while processing, not the dot always sitting on the green "on-device" colour.
    static func dotColor(for state: FlowBarState) -> Color {
        switch state {
        case .listening: Palette.recording
        case .processing: Palette.amber
        default: Palette.onDevice
        }
    }

    static func hotkeyLine(for mode: HotkeyMode) -> String {
        mode == .handsFree ? "Hotkey: Double-tap fn" : "Hotkey: Hold fn"
    }
}
