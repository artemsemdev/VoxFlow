import VoxFlowDictation

/// Pure state → menu bar text mappings (design MB-01). No view holds this logic itself.
enum MenuBarStatus {
    static func text(for state: FlowBarState) -> String {
        switch state {
        case .listening: "Listening…"
        case .processing: "Cleaning up…"
        default: "Ready · on-device"
        }
    }

    static func hotkeyLine(for mode: HotkeyMode) -> String {
        mode == .handsFree ? "Hotkey: Double-tap fn" : "Hotkey: Hold fn"
    }
}
