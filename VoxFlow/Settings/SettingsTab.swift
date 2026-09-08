import SwiftUI

/// Settings page tabs (design ST-01…06). The Settings page itself is Task 4 — this type exists now
/// only so the Files page's model banner can navigate straight to Models (controller ruling 1).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, hotkeys, models, audio, privacy, mcp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .hotkeys: "Hotkeys"
        case .models: "Models"
        case .audio: "Audio"
        case .privacy: "Privacy"
        case .mcp: "MCP"
        }
    }
}
