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

    var windowOpacity: Double {
        get { settings.windowOpacity }
        set { settings.windowOpacity = newValue }
    }

    var windowOpacityLabel: String { "\(Int((windowOpacity * 100).rounded()))%" }

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
        launchAtLogin = settings.launchAtLogin   // placeholder until every stored property is set — reconciled below

        // Apply the persisted appearance/position immediately — `SettingsServices` builds this VM
        // lazily (Task 3 scope: no `AppServices` wiring yet), so this is the first point either
        // adapter hears about the saved choice this launch.
        appearanceApplier.apply(settings.appearance)
        flowBarPositioning.apply(settings.flowBarPosition)

        // I3: the persisted toggle can drift from the real `SMAppService` registration (disabled
        // under System Settings › Login Items, or revoked after a move/re-sign) — read the actual
        // status at construction, not just the last value this app wrote.
        refreshLaunchAtLogin()
    }

    /// I3: re-reads `loginItem.isEnabled` and reconciles `launchAtLogin`/the persisted setting to
    /// match — called once at construction and again from `GeneralSettingsView`'s `.task` every
    /// time the General tab appears, so a status that changed since launch (or since the tab was
    /// last open) shows up without needing a relaunch.
    func refreshLaunchAtLogin() {
        let actual = loginItem.isEnabled
        launchAtLogin = actual
        settings.launchAtLogin = actual
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
