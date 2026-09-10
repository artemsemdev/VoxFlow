import Foundation
import Observation
import VoxFlowStorage

/// Settings › MCP Server (design ST-06, ST-06r). Toggles live directly on `settings` (`MCPSettings`,
/// exposed so the view can `@Bindable` it, same pattern as `PrivacyViewModel`/`DictationSettings`);
/// this view model owns the derived bits — endpoint/token copy, the tools list, the bound-endpoint/
/// port-busy note, connected clients, and the enable/regenerate flows that now talk to the real
/// server (`MCPServerControlling`) and client store (`MCPClientStoreProviding` — the same lazily-
/// resolved `MCPClientStore` the runner itself writes through, see `MCPServerService`'s doc).
@Observable @MainActor
final class MCPViewModel {
    enum Alert: Equatable { case regenerateToken }

    struct Tool: Identifiable {
        let id: String
        let name: String
        let description: String
    }

    /// One row in "Connected clients" — `lastUsedText` is pre-formatted (`relativeTime`, below) so
    /// the view holds no formatting rule of its own.
    struct MCPClientRow: Identifiable, Equatable {
        let id: Int64
        let name: String
        let lastUsedText: String
    }

    /// ST-06 "Tools exposed" — copy verbatim from the brief; order matches the canvas list.
    static let tools: [Tool] = [
        Tool(id: "transcribe_file", name: "transcribe_file", description: "Transcribe an audio file at a path; returns text or SRT"),
        Tool(id: "dictate", name: "dictate", description: "Start a dictation and return the cleaned-up text"),
        Tool(id: "search_history", name: "search_history", description: "Search past dictations — off by default"),
    ]

    static let defaultPort: UInt16 = 7331
    static let connectedClientsEmptyText = "No clients yet — connect Claude Desktop or Cursor with the token above."

    static let regenerateTitle = "Regenerate the access token?"
    static let regenerateMessage =
        "Claude Desktop and Cursor will be disconnected until you paste the new token into them. Approved clients are cleared."

    static let portBusyNote = "Port 7331 was busy — update your client with the Copy button."
    static let startFailureMessage = "Couldn't start the server — ports 7331–7340 are all in use."

    let settings: MCPSettings
    private let pasteboard: any Pasteboard
    private let server: any MCPServerControlling
    private let clientStoreProvider: any MCPClientStoreProviding
    private let now: @Sendable () -> Date

    var alert: Alert?
    private(set) var enabled: Bool
    private(set) var boundEndpoint: String
    private(set) var portNote: String?
    private(set) var startFailure: String?
    private(set) var clients: [MCPClientRow] = []

    /// Review fix (Important #2): `approvalObserver.onApproved` is wired at the end of `init`
    /// (after every stored property is set, so `self` is fully initialized) to refresh `clients` —
    /// so a client approved via ST-06a while this page is already open shows up live, not only on
    /// the next page-appear/revoke/regenerate. `[weak self]` — see the closure below — so this
    /// view model is never kept alive by the observer it hands a callback to.
    init(settings: MCPSettings, pasteboard: any Pasteboard, server: any MCPServerControlling,
         clientStoreProvider: any MCPClientStoreProviding, approvalObserver: any MCPApprovalObserving,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.server = server
        self.clientStoreProvider = clientStoreProvider
        self.now = now
        enabled = settings.enabled
        boundEndpoint = Self.endpointText(for: server.boundPort)
        portNote = Self.portNoteText(for: server.boundPort)
        approvalObserver.onApproved = { [weak self] in
            Task { @MainActor in await self?.refreshClients() }
        }
    }

    var maskedToken: String { settings.maskedToken }

    func copyEndpoint() { pasteboard.setString(boundEndpoint) }
    func copyToken() { pasteboard.setString(settings.token) }

    /// ST-06 "Regenerate" — shows the ST-06r confirmation rather than regenerating immediately.
    func requestRegenerate() { alert = .regenerateToken }

    /// ST-06r "Regenerate and copy" — a new token replaces the old one (invalid immediately) and
    /// goes straight to the clipboard, so pasting it into a client is the very next step. Ruling 4:
    /// also revokes every connected client, since the old token they authenticated with no longer
    /// works — leaving them "approved" against a token that can't reach the server would be a stale,
    /// misleading state.
    func confirmRegenerate() async {
        let newToken = settings.regenerate()
        pasteboard.setString(newToken)
        alert = nil
        let store = await clientStoreProvider.resolvedClientStore()
        await Task.detached(priority: .utility) { try? store.revokeAll() }.value
        await refreshClients()
    }

    func dismissAlert() { alert = nil }

    /// ST-06 "Enable MCP server" — starts/stops the real server through `server`. On
    /// `MCPServerError.noFreePort` (or any other start failure) the toggle snaps back to off and
    /// `startFailure` carries the exact copy, same "toggle snaps back on failure" pattern
    /// `GeneralViewModel.setLaunchAtLogin` uses for `SMAppService`.
    func setEnabled(_ newValue: Bool) async {
        startFailure = nil
        if newValue {
            do {
                try await server.start()
                settings.enabled = true
                enabled = true
            } catch {
                settings.enabled = false
                enabled = false
                startFailure = Self.startFailureMessage
            }
        } else {
            await server.stop()
            settings.enabled = false
            enabled = false
        }
        refreshBoundPort()
    }

    /// Re-syncs `enabled` and the bound-port-derived fields with reality, then reloads
    /// `clients` — called once when the MCP tab appears (`MCPSettingsView`'s `.task`, same
    /// reasoning as `GeneralViewModel.refreshLaunchAtLogin()`): the server may already be running,
    /// started by `AppDelegate` at launch before Settings was ever opened, so this view model's own
    /// `enabled`/`boundEndpoint` (set once at `init`) can be stale by the time the page appears.
    func refresh() async {
        enabled = settings.enabled
        refreshBoundPort()
        await refreshClients()
    }

    private func refreshBoundPort() {
        boundEndpoint = Self.endpointText(for: server.boundPort)
        portNote = Self.portNoteText(for: server.boundPort)
    }

    /// ST-06 "Connected clients" › Revoke.
    func revoke(_ id: Int64) async {
        let store = await clientStoreProvider.resolvedClientStore()
        await Task.detached(priority: .utility) { try? store.revoke(id: id) }.value
        await refreshClients()
    }

    func refreshClients() async {
        let store = await clientStoreProvider.resolvedClientStore()
        let rows = await Task.detached(priority: .utility) { (try? store.all()) ?? [] }.value
        let current = now()
        clients = rows.map { MCPClientRow(id: $0.id, name: $0.name, lastUsedText: "Last used \(Self.relativeTime(from: $0.lastSeen, now: current))") }
    }

    private static func endpointText(for port: UInt16?) -> String {
        "http://127.0.0.1:\(port ?? defaultPort)/mcp"
    }

    private static func portNoteText(for port: UInt16?) -> String? {
        guard let port, port != defaultPort else { return nil }
        return portBusyNote
    }

    /// A small, deterministic "time ago" — no `RelativeDateTimeFormatter` (locale-dependent
    /// pluralization would make exact-string tests brittle); `now` is injected so tests never race
    /// the wall clock. `nonisolated`: pure and stateless, so it needn't inherit this
    /// `@MainActor`-isolated class's default isolation — lets `MCPViewModelRelativeTimeTests` call
    /// it from a plain (non-`@MainActor`) test suite.
    nonisolated static func relativeTime(from date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86400: return "\(Int(seconds / 3600)) hr ago"
        default: return "\(Int(seconds / 86400)) d ago"
        }
    }
}
