import SwiftUI

/// Settings (design ST-01…06): segmented tabs across the top, `navigation.settingsTab` picks which
/// one shows. General and MCP (ST-01, ST-06) read from `SettingsServices.shared` (a separate
/// composition root from `AppServices` for now — see that type's doc comment).
struct SettingsPage: View {
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation

    private var model: ModelsViewModel { services.modelsViewModel }
    private var audio: AudioViewModel { services.audioViewModel }
    private var privacy: PrivacyViewModel { services.privacyViewModel }

    var body: some View {
        @Bindable var navigation = navigation
        VStack(spacing: 0) {
            Picker("Settings tab", selection: $navigation.settingsTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Group {
                switch navigation.settingsTab {
                case .general: GeneralSettingsView(general: SettingsServices.shared.generalViewModel)
                case .hotkeys: HotkeysSettingsView(settings: services.dictationSettings)
                case .models: ModelsSettingsView(model: model)
                case .audio: AudioSettingsView(audio: audio)
                case .privacy: PrivacySettingsView(privacy: privacy)
                case .mcp: MCPSettingsView(mcp: SettingsServices.shared.mcpViewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Settings")
    }
}
