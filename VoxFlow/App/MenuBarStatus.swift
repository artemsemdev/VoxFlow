import VoxFlowDictation

/// Pure state → menu bar status line mapping (design MB-01). No view holds this logic itself.
enum MenuBarStatus {
    static func text(for state: FlowBarState) -> String {
        switch state {
        case .listening: "Listening…"
        case .processing: "Cleaning up…"
        default: "Ready · on-device"
        }
    }
}
