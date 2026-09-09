import Observation

/// Settings › General (design ST-01). Toggles/pickers persist through `settings`
/// (`GeneralSettings`) and `dictationSettings` (for `language`); appearance and Flow Bar position
/// also apply live through their adapters the moment they change, and `launchAtLogin` goes through
/// `loginItem` — which can fail (denied in System Settings), snapping the toggle back to its
/// previous value rather than lying about what's actually registered (ruling 4, 3d "Toggles").
@Observable @MainActor
final class GeneralViewModel {
    private let settings: GeneralSettings
    private let dictationSettings: DictationSettings
    private let loginItem: any LoginItemControlling
    private let appearanceApplier: any AppearanceApplying
    private let flowBarPositioning: any FlowBarPositioning

    private(set) var launchAtLogin: Bool

    var showInMenuBar: Bool {
        get { settings.showInMenuBar }
        set { settings.showInMenuBar = newValue }
    }

    var playSounds: Bool {
        get { settings.playSounds }
        set { settings.playSounds = newValue }
    }

    var appearance: AppAppearance {
        get { settings.appearance }
        set {
            settings.appearance = newValue
            appearanceApplier.apply(newValue)
        }
    }

    var flowBarPosition: FlowBarPosition {
        get { settings.flowBarPosition }
        set {
            settings.flowBarPosition = newValue
            flowBarPositioning.apply(newValue)
        }
    }

    /// Bound straight through to `DictationSettings.language` (owner of ST-02/ST-05's language
    /// choice too) rather than duplicated on `GeneralSettings`.
    var language: String? {
        get { dictationSettings.language }
        set { dictationSettings.language = newValue }
    }

    init(settings: GeneralSettings, dictationSettings: DictationSettings, loginItem: any LoginItemControlling,
         appearanceApplier: any AppearanceApplying, flowBarPositioning: any FlowBarPositioning) {
        self.settings = settings
        self.dictationSettings = dictationSettings
        self.loginItem = loginItem
        self.appearanceApplier = appearanceApplier
        self.flowBarPositioning = flowBarPositioning
        launchAtLogin = settings.launchAtLogin

        // Apply the persisted appearance/position immediately — `SettingsServices` builds this VM
        // lazily (Task 3 scope: no `AppServices` wiring yet), so this is the first point either
        // adapter hears about the saved choice this launch.
        appearanceApplier.apply(settings.appearance)
        flowBarPositioning.apply(settings.flowBarPosition)
    }

    /// ST-01 "Launch at login" — registers/unregisters through `loginItem`; on failure (e.g. the
    /// user declined in System Settings) the toggle snaps back to what it was before this call,
    /// and nothing is persisted.
    func setLaunchAtLogin(_ newValue: Bool) {
        let previous = launchAtLogin
        launchAtLogin = newValue
        do {
            try loginItem.setEnabled(newValue)
            settings.launchAtLogin = newValue
        } catch {
            launchAtLogin = previous
        }
    }
}
