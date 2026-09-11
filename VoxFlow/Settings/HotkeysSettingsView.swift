import SwiftUI
import VoxFlowDictation

/// Settings › Hotkeys (design ST-02): thin `ScrollView` wrapper around `HotkeysSettingsBody`, which
/// holds the actual layout — split the same way `HistoryPage`/`HistoryPageBody` are, so
/// `SettingsRenderTests` can render the content directly (`ImageRenderer` doesn't reliably capture
/// `ScrollView`).
struct HotkeysSettingsView: View {
    let settings: DictationSettings
    var recorder: ShortcutRecorderModel? = nil
    @State private var fnWarning = FnSystemActionWarningState()

    var body: some View {
        ScrollView { HotkeysSettingsBody(settings: settings, recordShortcut: { recorder?.begin($0) }, fnWarning: fnWarning) }
            .frame(maxWidth: .infinity)
            .sheet(isPresented: Binding(get: { recorder?.isRecording == true }, set: { if !$0 { recorder?.cancel() } })) {
                if let recorder { ShortcutRecorderView(model: recorder) }
            }
            .onDisappear { recorder?.cancel() }
    }
}

/// ST-02 rows read the persisted bindings and open the shared recorder.
struct HotkeysSettingsBody: View {
    let settings: DictationSettings
    var recordShortcut: (ShortcutAction) -> Void = { _ in }
    var fnWarning: FnSystemActionWarningState? = nil

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
                ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                    Button { recordShortcut(action) } label: { rowView(action) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("shortcut-" + action.rawValue)
                        .accessibilityLabel("Record shortcut for " + action.title)
                    if index < ShortcutAction.allCases.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if settings.shortcuts.usesFunctionKey, let fnWarning { FnSystemActionWarning(state: fnWarning) }

            Text(HotkeysCopy.footer(mode: settings.hotkeyMode))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func rowView(_ action: ShortcutAction) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(action.title).fontWeight(.medium)
                Text(action.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach(Array(settings.shortcuts[action].keycaps.enumerated()), id: \.offset) { _, key in KeycapView(text: key) }
                if action == .pushToTalk || settings.shortcuts[action].doubleTap {
                    Text(action == .pushToTalk ? "hold" : "double-tap").font(.caption2).foregroundStyle(.secondary).padding(.leading, 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
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
