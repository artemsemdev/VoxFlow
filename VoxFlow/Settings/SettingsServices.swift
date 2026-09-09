/// Thin forwarder to `AppServices.shared` (design ST-01, ST-06). Used to be its own composition
/// root, built separately from `AppServices` because another Task in this plan was still editing
/// `AppServices.swift`; the controller task (this one) folded `generalSettings`/`mcpSettings`/
/// `generalViewModel`/`mcpViewModel`/`soundCoordinator` into `AppServices` itself (built eagerly, at
/// real launch, so `GeneralViewModel`'s appearance/Flow Bar adapters apply immediately rather than
/// only once Settings is opened) and kept this type only so `SettingsPage`'s existing
/// `SettingsServices.shared.…` call sites keep compiling unchanged.
@MainActor
final class SettingsServices {
    static let shared = SettingsServices()

    var generalSettings: GeneralSettings { AppServices.shared.generalSettings }
    var mcpSettings: MCPSettings { AppServices.shared.mcpSettings }
    var generalViewModel: GeneralViewModel { AppServices.shared.generalViewModel }
    var mcpViewModel: MCPViewModel { AppServices.shared.mcpViewModel }
    var soundCoordinator: SoundCoordinator { AppServices.shared.soundCoordinator }

    private init() {}
}
