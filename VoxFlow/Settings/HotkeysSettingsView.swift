import SwiftUI
import VoxFlowDictation

/// Settings › Hotkeys (design ST-02): thin `ScrollView` wrapper around `HotkeysSettingsBody`, which
/// holds the actual layout — split the same way `HistoryPage`/`HistoryPageBody` are, so
/// `SettingsRenderTests` can render the content directly (`ImageRenderer` doesn't reliably capture
/// `ScrollView`).
struct HotkeysSettingsView: View {
    let settings: DictationSettings

    var body: some View {
        ScrollView { HotkeysSettingsBody(settings: settings) }
            .frame(maxWidth: .infinity)
    }
}

/// Recording a shortcut (ST-02r/ST-02c) is phase 4 — rows here are read-only, so no view model
/// beyond the `DictationSettings` binding for "Default mode".
struct HotkeysSettingsBody: View {
    let settings: DictationSettings

    private struct Row: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let keys: [String]
        let hint: String?
        var disabled = false
    }

    private static let rows: [Row] = [
        Row(id: "push", title: "Push-to-talk", subtitle: "Hold to dictate, release to insert", keys: ["fn"], hint: "hold"),
        Row(id: "free", title: "Hands-free", subtitle: "Press to start, press again to stop", keys: ["fn", "fn"], hint: "double-tap"),
        Row(id: "cancel", title: "Cancel", subtitle: "Discard the current dictation", keys: ["esc"], hint: nil),
        Row(id: "reinsert", title: "Re-insert last dictation", subtitle: "Useful when the wrong field had focus",
           keys: ["⌥", "⌘", "V"], hint: nil, disabled: true),
    ]

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            Picker("Default mode", selection: $settings.hotkeyMode) {
                Text(HotkeysCopy.modeLabel(.pushToTalk)).tag(HotkeyMode.pushToTalk)
                Text(HotkeysCopy.modeLabel(.handsFree)).tag(HotkeyMode.handsFree)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            VStack(spacing: 0) {
                ForEach(Array(Self.rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row)
                    if index < Self.rows.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(HotkeysCopy.footer(mode: settings.hotkeyMode))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).fontWeight(.medium)
                Text(row.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach(Array(row.keys.enumerated()), id: \.offset) { _, key in KeycapView(text: key) }
                if let hint = row.hint {
                    Text(hint).font(.caption2).foregroundStyle(.secondary).padding(.leading, 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(row.disabled ? 0.5 : 1)
    }
}

/// The Hotkeys footer copy (ST-02: "Click any shortcut to record a new one. Default mode is
/// currently {mode} — change it in Tweaks or here."), pulled into its own testable enum so the
/// exact wording/mode-label mapping can be checked without rendering the view.
enum HotkeysCopy {
    static func modeLabel(_ mode: HotkeyMode) -> String {
        switch mode {
        case .pushToTalk: "Push-to-talk"
        case .handsFree: "Hands-free"
        }
    }

    static func footer(mode: HotkeyMode) -> String {
        "Click any shortcut to record a new one. Default mode is currently \(modeLabel(mode)) — change it in Tweaks or here."
    }
}
