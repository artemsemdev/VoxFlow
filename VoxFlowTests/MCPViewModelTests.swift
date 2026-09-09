import Testing
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("MCPViewModel")
@MainActor
struct MCPViewModelTests {
    private func harness() -> (settings: MCPSettings, tokenStore: FakeTokenStore, pasteboard: FakePasteboard, vm: MCPViewModel) {
        let tokenStore = FakeTokenStore()
        let settings = MCPSettings(store: InMemoryKeyValueStore(), token: tokenStore)
        let pasteboard = FakePasteboard()
        return (settings, tokenStore, pasteboard, MCPViewModel(settings: settings, pasteboard: pasteboard))
    }

    @Test("copyEndpoint copies the fixed localhost endpoint")
    func copyEndpoint() {
        let h = harness()
        h.vm.copyEndpoint()
        #expect(h.pasteboard.strings == ["http://127.0.0.1:7331/mcp"])
    }

    @Test("copyToken copies the current (unmasked) token")
    func copyToken() {
        let h = harness()
        let token = h.settings.token
        h.vm.copyToken()
        #expect(h.pasteboard.strings == [token])
    }

    @Test("requestRegenerate shows the ST-06r confirmation without regenerating yet")
    func requestRegenerateShowsAlert() {
        let h = harness()
        let original = h.settings.token
        h.vm.requestRegenerate()
        #expect(h.vm.alert == .regenerateToken)
        #expect(h.settings.token == original)
        #expect(h.pasteboard.strings.isEmpty)
    }

    @Test("confirmRegenerate regenerates, copies the new token and dismisses the alert")
    func confirmRegenerateRegeneratesAndCopies() {
        let h = harness()
        let original = h.settings.token
        h.vm.requestRegenerate()
        h.vm.confirmRegenerate()
        #expect(h.vm.alert == nil)
        #expect(h.settings.token != original)
        #expect(h.pasteboard.strings == [h.settings.token])
    }

    @Test("dismissAlert clears the alert without regenerating")
    func dismissAlertCancels() {
        let h = harness()
        let original = h.settings.token
        h.vm.requestRegenerate()
        h.vm.dismissAlert()
        #expect(h.vm.alert == nil)
        #expect(h.settings.token == original)
        #expect(h.pasteboard.strings.isEmpty)
    }

    @Test("tool toggles default on/off matches MCPSettings and persist through it")
    func toolTogglesPassThroughSettings() {
        let h = harness()
        #expect(h.settings.toolTranscribeFile == true)
        #expect(h.settings.toolDictate == true)
        #expect(h.settings.toolSearchHistory == false)
        h.settings.toolSearchHistory = true
        #expect(h.settings.toolSearchHistory == true)
    }
}
