import SwiftUI

/// Settings (design ST-01…06): segmented tabs across the top, `navigation.settingsTab` picks which
/// one shows. Hotkeys/Models/Audio/Privacy (ST-02…05) are real; General and MCP (ST-01, ST-06) read
/// "Coming in a later phase", matching `PlaceholderPageView`'s treatment of the not-yet-built
/// sidebar pages.
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
                case .hotkeys: HotkeysSettingsView(settings: services.dictationSettings)
                case .models: ModelsSettingsView(model: model)
                case .audio: AudioSettingsView(audio: audio)
                case .privacy: PrivacySettingsView(privacy: privacy)
                case .general, .mcp: SettingsPlaceholderTab(tab: navigation.settingsTab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Settings")
    }
}

/// Stand-in content for the tabs not yet built (General/Hotkeys/Audio/Privacy/MCP — phases 2c+).
private struct SettingsPlaceholderTab: View {
    let tab: SettingsTab

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "gearshape")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(tab.title)
                .font(.title2.weight(.semibold))
            Text("Coming in a later phase.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
