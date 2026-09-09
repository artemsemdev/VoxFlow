import VoxFlowCore

/// Composition root for Settings › General and Settings › MCP Server (design ST-01, ST-06) — a
/// separate singleton from `AppServices` for now because another Task in this same plan is editing
/// `AppServices.swift`; a later controller task folds this into it. Everything here is built
/// lazily from `AppServices.shared`'s own dependencies (`dictationSettings`, `dictation`,
/// `flowBar`), mirroring how `AppServices.live()` builds its own view models.
@MainActor
final class SettingsServices {
    static let shared = SettingsServices()

    private let store: any KeyValueStore

    lazy var generalSettings = GeneralSettings(store: store)
    lazy var mcpSettings = MCPSettings(store: store, token: KeychainTokenStore())

    lazy var generalViewModel = GeneralViewModel(
        settings: generalSettings,
        dictationSettings: AppServices.shared.dictationSettings,
        loginItem: SMLoginItem(),
        appearanceApplier: NSAppearanceApplier(),
        flowBarPositioning: AppServices.shared.flowBar
    )

    lazy var mcpViewModel = MCPViewModel(settings: mcpSettings, pasteboard: SystemPasteboard())

    /// Plays ST-01's start/end sounds off `AppServices.shared.dictation`'s state. Built lazily but
    /// not yet bound to the live coordinator here — this task is UI-only (Settings pages + the
    /// pieces they need); wiring `bind(to:)` into the real app-launch sequence is the controller
    /// task's job once this folds into `AppServices` (Task 3 file-scope note).
    lazy var soundCoordinator = SoundCoordinator(settings: generalSettings, player: NSSoundPlayer())

    private init(store: any KeyValueStore = UserDefaultsKeyValueStore()) {
        self.store = store
    }
}
