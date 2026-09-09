import Observation

/// Settings › MCP Server (design ST-06, ST-06r). Toggles live directly on `settings` (`MCPSettings`,
/// exposed so the view can `@Bindable` it, same pattern as `PrivacyViewModel`/`DictationSettings`);
/// this view model owns the derived bits — endpoint/token copy, the tools list, and the regenerate
/// confirmation flow.
@Observable @MainActor
final class MCPViewModel {
    enum Alert: Equatable { case regenerateToken }

    struct Tool: Identifiable {
        let id: String
        let name: String
        let description: String
    }

    /// ST-06 "Tools exposed" — copy verbatim from the brief; order matches the canvas list.
    static let tools: [Tool] = [
        Tool(id: "transcribe_file", name: "transcribe_file", description: "Transcribe an audio file at a path; returns text or SRT"),
        Tool(id: "dictate", name: "dictate", description: "Start a dictation and return the cleaned-up text"),
        Tool(id: "search_history", name: "search_history", description: "Search past dictations — off by default"),
    ]

    static let endpoint = "http://127.0.0.1:7331/mcp"
    static let connectedClientsEmptyText = "No clients yet — connect Claude Desktop or Cursor with the token above."

    static let regenerateTitle = "Regenerate the access token?"
    static let regenerateMessage = "Claude Desktop and Cursor will be disconnected until you paste the new token into them."

    let settings: MCPSettings
    private let pasteboard: any Pasteboard

    var alert: Alert?

    init(settings: MCPSettings, pasteboard: any Pasteboard) {
        self.settings = settings
        self.pasteboard = pasteboard
    }

    var maskedToken: String { settings.maskedToken }

    func copyEndpoint() { pasteboard.setString(Self.endpoint) }
    func copyToken() { pasteboard.setString(settings.token) }

    /// ST-06 "Regenerate" — shows the ST-06r confirmation rather than regenerating immediately.
    func requestRegenerate() { alert = .regenerateToken }

    /// ST-06r "Regenerate and copy" — a new token replaces the old one (invalid immediately) and
    /// goes straight to the clipboard, so pasting it into a client is the very next step.
    func confirmRegenerate() {
        let newToken = settings.regenerate()
        pasteboard.setString(newToken)
        alert = nil
    }

    func dismissAlert() { alert = nil }
}
