import Testing
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("GeneralViewModel")
@MainActor
struct GeneralViewModelTests {
    @MainActor
    private struct Harness {
        let settings: GeneralSettings
        let dictationSettings: DictationSettings
        let loginItem: FakeLoginItem
        let appearance: FakeAppearanceApplying
        let position: FakeFlowBarPositioning
        let vm: GeneralViewModel

        init(loginItemEnabled: Bool = false, loginItemThrows: Bool = false) {
            settings = GeneralSettings(store: InMemoryKeyValueStore())
            dictationSettings = DictationSettings(store: InMemoryKeyValueStore())
            loginItem = FakeLoginItem(isEnabled: loginItemEnabled, shouldThrow: loginItemThrows)
            appearance = FakeAppearanceApplying()
            position = FakeFlowBarPositioning()
            vm = GeneralViewModel(settings: settings, dictationSettings: dictationSettings, loginItem: loginItem,
                                  appearanceApplier: appearance, flowBarPositioning: position)
        }
    }

    @Test("init applies the persisted appearance and Flow Bar position immediately")
    func initAppliesPersistedChoices() {
        let h = Harness()
        #expect(h.appearance.applied == [.system])
        #expect(h.position.applied == [.bottomCenter])
    }

    @Test("appearance change persists and applies")
    func appearanceChangePersistsAndApplies() {
        let h = Harness()
        h.vm.appearance = .dark
        #expect(h.settings.appearance == .dark)
        #expect(h.appearance.applied == [.system, .dark])
    }

    @Test("window opacity binds to settings and displays the current whole percentage")
    func opacityBindsToSettings() {
        let h = Harness()
        #expect(h.vm.windowOpacityLabel == "100%")
        h.vm.windowOpacity = 0.55
        #expect(h.settings.windowOpacity == 0.55)
        #expect(h.vm.windowOpacityLabel == "55%")
        h.settings.windowOpacity = 0.2
        #expect(h.vm.windowOpacity == 0.2)
        #expect(h.vm.windowOpacityLabel == "20%")
    }

    @Test("Flow Bar position change persists and applies")
    func positionChangePersistsAndApplies() {
        let h = Harness()
        h.vm.flowBarPosition = .bottomRight
        #expect(h.settings.flowBarPosition == .bottomRight)
        #expect(h.position.applied == [.bottomCenter, .bottomRight])
    }

    @Test("language reads/writes DictationSettings.language directly")
    func languageBindsToDictationSettings() {
        let h = Harness()
        #expect(h.vm.language == nil)
        h.vm.language = "es"
        #expect(h.dictationSettings.language == "es")
        h.dictationSettings.language = "de"
        #expect(h.vm.language == "de")
    }

    @Test("showInMenuBar and playSounds pass through to settings")
    func togglesPassThrough() {
        let h = Harness()
        h.vm.showInMenuBar = false
        #expect(h.settings.showInMenuBar == false)
        h.vm.playSounds = false
        #expect(h.settings.playSounds == false)
    }

    @Test("launchAtLogin registers through loginItem and persists on success")
    func launchAtLoginSucceeds() {
        let h = Harness()
        h.vm.setLaunchAtLogin(true)
        #expect(h.vm.launchAtLogin == true)
        #expect(h.settings.launchAtLogin == true)
        #expect(h.loginItem.setCalls == [true])
    }

    @Test("launchAtLogin snaps back to the previous value and doesn't persist when the adapter throws (3d Toggles)")
    func launchAtLoginSnapsBackOnFailure() {
        let h = Harness(loginItemEnabled: false, loginItemThrows: true)
        #expect(h.vm.launchAtLogin == false)
        h.vm.setLaunchAtLogin(true)
        #expect(h.vm.launchAtLogin == false)              // snapped back
        #expect(h.settings.launchAtLogin == false)         // never persisted
        #expect(h.loginItem.setCalls == [true])
    }

    @Test("launchAtLogin snap-back restores true, not always false, when disabling fails")
    func launchAtLoginSnapsBackToTrueWhenDisablingFails() {
        let h = Harness(loginItemEnabled: true, loginItemThrows: false)
        h.vm.setLaunchAtLogin(true)
        #expect(h.vm.launchAtLogin == true)
        h.loginItem.setShouldThrow(true)
        h.vm.setLaunchAtLogin(false)
        #expect(h.vm.launchAtLogin == true)                // snapped back to true, not false
        #expect(h.settings.launchAtLogin == true)
    }

    @Test("init reads launchAtLogin from LoginItemControlling.isEnabled, not the persisted setting, and reconciles the persisted value (I3)")
    func initReconcilesFromRealStatus() {
        // `GeneralSettings.launchAtLogin` defaults to false; a fake reporting the opposite (true)
        // must win — this is exactly the drift ruling 4 / design 3d "Toggles" is trying to prevent,
        // just on the read side instead of the write side. Built by hand (not via `Harness`) so the
        // persisted value can be inspected *before* `GeneralViewModel.init` reconciles it.
        let settings = GeneralSettings(store: InMemoryKeyValueStore())
        #expect(settings.launchAtLogin == false)   // sanity: nothing set it yet
        let loginItem = FakeLoginItem(isEnabled: true)

        let vm = GeneralViewModel(settings: settings, dictationSettings: DictationSettings(store: InMemoryKeyValueStore()),
                                  loginItem: loginItem, appearanceApplier: FakeAppearanceApplying(), flowBarPositioning: FakeFlowBarPositioning())
        #expect(vm.launchAtLogin == true)          // reads the system, not the stale persisted `false`
        #expect(settings.launchAtLogin == true)    // and reconciles the persisted value too
    }

    @Test("refreshLaunchAtLogin() re-reads LoginItemControlling.isEnabled, picking up a status change made outside VoxFlow (I3)")
    func refreshPicksUpExternalChange() throws {
        let h = Harness(loginItemEnabled: false)
        #expect(h.vm.launchAtLogin == false)

        // Simulates the registration changing by some means other than `vm.setLaunchAtLogin` (System
        // Settings › Login Items, or a revoked registration) — not yet reflected in the view model.
        try h.loginItem.setEnabled(true)
        #expect(h.vm.launchAtLogin == false)

        h.vm.refreshLaunchAtLogin()
        #expect(h.vm.launchAtLogin == true)
        #expect(h.settings.launchAtLogin == true)
    }
}
