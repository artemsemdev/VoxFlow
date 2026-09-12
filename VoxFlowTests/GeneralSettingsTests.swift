import Testing
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("GeneralSettings")
@MainActor
struct GeneralSettingsTests {
    @Test("defaults match the design (ruling 4: launchAtLogin off); values persist across reloads")
    func defaultsAndPersistence() {
        let store = InMemoryKeyValueStore()
        let s = GeneralSettings(store: store)
        #expect(s.launchAtLogin == false)
        #expect(s.showInMenuBar == true)
        #expect(s.playSounds == true)
        #expect(s.appearance == .system)
        #expect(s.flowBarPosition == .bottomCenter)

        s.launchAtLogin = true
        s.showInMenuBar = false
        s.playSounds = false
        s.appearance = .dark
        s.flowBarPosition = .topCenter

        let reloaded = GeneralSettings(store: store)
        #expect(reloaded.launchAtLogin == true)
        #expect(reloaded.showInMenuBar == false)
        #expect(reloaded.playSounds == false)
        #expect(reloaded.appearance == .dark)
        #expect(reloaded.flowBarPosition == .topCenter)
    }
    @Test("window opacity defaults to opaque, persists and clamps invalid values")
    func windowOpacityPersistence() {
        let store = InMemoryKeyValueStore()
        let settings = GeneralSettings(store: store)
        #expect(settings.windowOpacity == 1)
        settings.windowOpacity = 0.55
        #expect(GeneralSettings(store: store).windowOpacity == 0.55)
        settings.windowOpacity = 0
        #expect(settings.windowOpacity == 0.2)
        settings.windowOpacity = 2
        #expect(settings.windowOpacity == 1)
        settings.windowOpacity = .nan
        #expect(settings.windowOpacity == 1)
        for invalid in ["nan", "inf", "broken"] {
            store.set(invalid, forKey: GeneralSettings.Keys.windowOpacity)
            #expect(GeneralSettings(store: store).windowOpacity == 1)
        }
        store.set("0.1", forKey: GeneralSettings.Keys.windowOpacity)
        #expect(GeneralSettings(store: store).windowOpacity == 0.2)
    }

}
