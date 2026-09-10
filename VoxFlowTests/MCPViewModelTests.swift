import Foundation
import Testing
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("MCPViewModel")
@MainActor
struct MCPViewModelTests {
    private func harness(now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) })
        throws -> (settings: MCPSettings, tokenStore: FakeTokenStore, pasteboard: FakePasteboard, server: FakeMCPServer, store: MCPClientStore, vm: MCPViewModel) {
        let tokenStore = FakeTokenStore()
        let settings = MCPSettings(store: InMemoryKeyValueStore(), token: tokenStore)
        let pasteboard = FakePasteboard()
        let store = try MCPClientStore(database: VoxFlowDatabase.inMemory())
        let server = FakeMCPServer(store: store)
        let vm = MCPViewModel(settings: settings, pasteboard: pasteboard, server: server, clientStoreProvider: server, now: now)
        return (settings, tokenStore, pasteboard, server, store, vm)
    }

    // MARK: endpoint / token copy

    @Test("copyEndpoint copies the bound endpoint — the default port 7331 before any start")
    func copyEndpoint() throws {
        let h = try harness()
        h.vm.copyEndpoint()
        #expect(h.pasteboard.strings == ["http://127.0.0.1:7331/mcp"])
    }

    @Test("copyToken copies the current (unmasked) token")
    func copyToken() throws {
        let h = try harness()
        let token = h.settings.token
        h.vm.copyToken()
        #expect(h.pasteboard.strings == [token])
    }

    @Test("requestRegenerate shows the ST-06r confirmation without regenerating yet")
    func requestRegenerateShowsAlert() throws {
        let h = try harness()
        let original = h.settings.token
        h.vm.requestRegenerate()
        #expect(h.vm.alert == .regenerateToken)
        #expect(h.settings.token == original)
        #expect(h.pasteboard.strings.isEmpty)
    }

    @Test("confirmRegenerate regenerates, copies the new token, dismisses the alert, and clears connected clients (ruling 4)")
    func confirmRegenerateRegeneratesCopiesAndClearsClients() async throws {
        let h = try harness()
        let original = h.settings.token
        try h.store.approve(name: "Cursor", path: "/Applications/Cursor.app", now: Date(timeIntervalSince1970: 1_699_000_000))
        h.vm.requestRegenerate()
        await h.vm.confirmRegenerate()
        #expect(h.vm.alert == nil)
        #expect(h.settings.token != original)
        #expect(h.pasteboard.strings == [h.settings.token])
        #expect(h.vm.clients.isEmpty)
        #expect(try h.store.all().isEmpty)
    }

    @Test("dismissAlert clears the alert without regenerating")
    func dismissAlertCancels() throws {
        let h = try harness()
        let original = h.settings.token
        h.vm.requestRegenerate()
        h.vm.dismissAlert()
        #expect(h.vm.alert == nil)
        #expect(h.settings.token == original)
        #expect(h.pasteboard.strings.isEmpty)
    }

    @Test("tool toggles default on/off matches MCPSettings and persist through it")
    func toolTogglesPassThroughSettings() throws {
        let h = try harness()
        #expect(h.settings.toolTranscribeFile == true)
        #expect(h.settings.toolDictate == true)
        #expect(h.settings.toolSearchHistory == false)
        h.settings.toolSearchHistory = true
        #expect(h.settings.toolSearchHistory == true)
    }

    // MARK: bound endpoint / port note

    @Test("boundEndpoint/portNote reflect the server's actual bound port once started")
    func boundEndpointAndPortNoteAfterStart() async throws {
        let h = try harness()
        h.server.portToReturn = 7331
        await h.vm.setEnabled(true)
        #expect(h.vm.boundEndpoint == "http://127.0.0.1:7331/mcp")
        #expect(h.vm.portNote == nil)
    }

    @Test("a non-default bound port (7331 was busy) shows the exact port-busy note")
    func portNoteWhenPortIsBusy() async throws {
        let h = try harness()
        h.server.portToReturn = 7332
        await h.vm.setEnabled(true)
        #expect(h.vm.boundEndpoint == "http://127.0.0.1:7332/mcp")
        #expect(h.vm.portNote == "Port 7331 was busy — update your client with the Copy button.")
    }

    // MARK: enable / disable

    @Test("setEnabled(true) starts the server and persists enabled")
    func setEnabledTrueStartsServer() async throws {
        let h = try harness()
        #expect(h.vm.enabled == false)
        await h.vm.setEnabled(true)
        #expect(h.vm.enabled == true)
        #expect(h.settings.enabled == true)
        #expect(h.server.startCount == 1)
        #expect(h.vm.startFailure == nil)
    }

    @Test("setEnabled(true) on MCPServerError.noFreePort snaps the toggle back off and shows the exact failure copy")
    func setEnabledTrueSnapsBackOnNoFreePort() async throws {
        let h = try harness()
        h.server.startError = MCPServerError.noFreePort
        await h.vm.setEnabled(true)
        #expect(h.vm.enabled == false)
        #expect(h.settings.enabled == false)
        #expect(h.vm.startFailure == "Couldn't start the server — ports 7331–7340 are all in use.")
    }

    @Test("setEnabled(false) stops the server and persists disabled")
    func setEnabledFalseStopsServer() async throws {
        let h = try harness()
        await h.vm.setEnabled(true)
        await h.vm.setEnabled(false)
        #expect(h.vm.enabled == false)
        #expect(h.settings.enabled == false)
        #expect(h.server.stopCount == 1)
    }

    // MARK: refresh (page appear — server may already be running from AppDelegate)

    @Test("refresh() re-syncs enabled/boundEndpoint from the server started outside this view model")
    func refreshSyncsFromServerStartedElsewhere() async throws {
        let h = try harness()
        h.settings.enabled = true             // as if AppDelegate already started it at launch
        h.server.portToReturn = 7333
        try await h.server.start()             // simulating AppDelegate's own call, not the view model's
        await h.vm.refresh()
        #expect(h.vm.enabled == true)
        #expect(h.vm.boundEndpoint == "http://127.0.0.1:7333/mcp")
    }

    // MARK: connected clients

    @Test("refreshClients renders one row per mcp_clients record, most-recently-seen first, with \"Last used …\"")
    func refreshClientsRendersRows() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try harness(now: { now })
        try h.store.recordSighting(name: "Cursor", path: "/Applications/Cursor.app", now: now.addingTimeInterval(-90))     // 1.5 min ago
        try h.store.recordSighting(name: "Claude Desktop", path: "/Applications/Claude.app", now: now.addingTimeInterval(-30))  // 30 s ago

        await h.vm.refreshClients()
        #expect(h.vm.clients.map(\.name) == ["Claude Desktop", "Cursor"])
        #expect(h.vm.clients[0].lastUsedText == "Last used just now")
        #expect(h.vm.clients[1].lastUsedText == "Last used 1 min ago")
    }

    @Test("revoke removes the client and refreshes the list")
    func revokeRemovesClient() async throws {
        let h = try harness()
        let record = try h.store.recordSighting(name: "Cursor", path: "/Applications/Cursor.app", now: Date())
        await h.vm.refreshClients()
        #expect(h.vm.clients.count == 1)

        await h.vm.revoke(record.id)
        #expect(h.vm.clients.isEmpty)
        #expect(try h.store.all().isEmpty)
    }
}

/// `MCPViewModel.relativeTime` — pure, no window/server needed.
@Suite("MCPViewModel.relativeTime")
struct MCPViewModelRelativeTimeTests {
    @Test("thresholds: <60s just now, <1h minutes, <1d hours, else days")
    func thresholds() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(MCPViewModel.relativeTime(from: now, now: now) == "just now")
        #expect(MCPViewModel.relativeTime(from: now.addingTimeInterval(-59), now: now) == "just now")
        #expect(MCPViewModel.relativeTime(from: now.addingTimeInterval(-60), now: now) == "1 min ago")
        #expect(MCPViewModel.relativeTime(from: now.addingTimeInterval(-3599), now: now) == "59 min ago")
        #expect(MCPViewModel.relativeTime(from: now.addingTimeInterval(-3600), now: now) == "1 hr ago")
        #expect(MCPViewModel.relativeTime(from: now.addingTimeInterval(-86399), now: now) == "23 hr ago")
        #expect(MCPViewModel.relativeTime(from: now.addingTimeInterval(-86400), now: now) == "1 d ago")
    }
}
