import SwiftUI

/// Settings › General (design ST-01): thin `ScrollView` wrapper around `GeneralSettingsBody` —
/// split the same way `PrivacySettingsView`/`PrivacySettingsBody` are, so `SettingsRenderTests`
/// can render the content directly (`ImageRenderer` doesn't reliably capture `ScrollView`).
struct GeneralSettingsView: View {
    let general: GeneralViewModel

    var body: some View {
        ScrollView { GeneralSettingsBody(general: general) }
            .frame(maxWidth: .infinity)
            // I3: re-reads the real `SMAppService` status every time this tab appears, catching a
            // status that changed since launch (System Settings › Login Items, or a revoked
            // registration) without needing a relaunch.
            .task { general.refreshLaunchAtLogin() }
    }
}

struct GeneralSettingsBody: View {
    let general: GeneralViewModel

    private static let languages: [(code: String?, label: String)] = [
        (nil, "Auto-detect"), ("en", "English"), ("es", "Español"), ("fr", "Français"),
        ("de", "Deutsch"), ("ja", "日本語"), ("pt", "Português"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 0) {
                launchAtLoginRow
                Divider().padding(.leading, 16)
                showInMenuBarRow
                Divider().padding(.leading, 16)
                playSoundsRow
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(spacing: 0) {
                appearanceRow
                Divider().padding(.leading, 16)
                flowBarPositionRow
                Divider().padding(.leading, 16)
                languageRow
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(20)
        .frame(maxWidth: 640, alignment: .leading)
    }

    // MARK: toggles

    private var launchAtLoginRow: some View {
        HStack {
            Text("Launch at login")
            Spacer()
            Toggle("Launch at login", isOn: launchAtLoginBinding).labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { general.launchAtLogin }, set: { general.setLaunchAtLogin($0) })
    }

    private var showInMenuBarRow: some View {
        HStack {
            Text("Show in menu bar")
            Spacer()
            Toggle("Show in menu bar", isOn: Binding(get: { general.showInMenuBar }, set: { general.showInMenuBar = $0 })).labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var playSoundsRow: some View {
        HStack {
            Text("Play sounds when dictation starts and ends")
            Spacer()
            Toggle("Play sounds when dictation starts and ends", isOn: Binding(get: { general.playSounds }, set: { general.playSounds = $0 })).labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: pickers

    private var appearanceRow: some View {
        HStack {
            Text("Appearance")
            Spacer()
            Picker("Appearance", selection: Binding(get: { general.appearance }, set: { general.appearance = $0 })) {
                ForEach(AppAppearance.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 140)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var flowBarPositionRow: some View {
        HStack {
            Text("Flow Bar position")
            Spacer()
            Picker("Flow Bar position", selection: Binding(get: { general.flowBarPosition }, set: { general.flowBarPosition = $0 })) {
                ForEach(FlowBarPosition.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var languageRow: some View {
        HStack {
            Text("Dictation language")
            Spacer()
            Picker("Dictation language", selection: Binding(get: { general.language }, set: { general.language = $0 })) {
                ForEach(Array(Self.languages.enumerated()), id: \.offset) { _, choice in
                    Text(choice.label).tag(choice.code)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
