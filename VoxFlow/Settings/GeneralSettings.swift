import Observation
import VoxFlowCore

/// Settings › General choices (design ST-01) that aren't already owned elsewhere — dictation
/// language lives on `DictationSettings.language` (`GeneralViewModel` binds to it directly)
/// instead of being duplicated here.
///
/// `launchAtLogin` defaults to **off**: the canvas mock shows it on, but registering a login item
/// the moment the app first launches — before the person has asked for it — would be a consent
/// violation (ruling 4 in the phase 4b plan header).
@Observable @MainActor
final class GeneralSettings {
    private let store: any KeyValueStore

    enum Keys {
        static let launchAtLogin = "general.launchAtLogin"
        static let showInMenuBar = "general.showInMenuBar"
        static let playSounds = "general.playSounds"
        static let appearance = "general.appearance"
        static let flowBarPosition = "general.flowBarPosition"
    }

    var launchAtLogin: Bool { didSet { store.set(launchAtLogin ? "1" : "0", forKey: Keys.launchAtLogin) } }
    var showInMenuBar: Bool { didSet { store.set(showInMenuBar ? "1" : "0", forKey: Keys.showInMenuBar) } }
    var playSounds: Bool { didSet { store.set(playSounds ? "1" : "0", forKey: Keys.playSounds) } }
    var appearance: AppAppearance { didSet { store.set(appearance.rawValue, forKey: Keys.appearance) } }
    var flowBarPosition: FlowBarPosition { didSet { store.set(flowBarPosition.rawValue, forKey: Keys.flowBarPosition) } }

    init(store: any KeyValueStore) {
        self.store = store
        launchAtLogin = store.string(forKey: Keys.launchAtLogin) == "1"                 // default off
        showInMenuBar = store.string(forKey: Keys.showInMenuBar) != "0"                 // default on
        playSounds = store.string(forKey: Keys.playSounds) != "0"                       // default on
        appearance = store.string(forKey: Keys.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system
        flowBarPosition = store.string(forKey: Keys.flowBarPosition).flatMap(FlowBarPosition.init(rawValue:)) ?? .bottomCenter
    }
}
