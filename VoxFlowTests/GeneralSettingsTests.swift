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
}
