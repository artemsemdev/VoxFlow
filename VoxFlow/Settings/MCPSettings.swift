import Foundation
import Observation
import VoxFlowCore

/// Reads/writes the MCP access token, behind a protocol so `MCPSettingsTests` can fake it without
/// touching the real Keychain.
protocol TokenStoring: Sendable {
    func read() throws -> String?
    func write(_ token: String) throws
}

/// Production `TokenStoring`: `KeychainString` over the generic-password item
/// `dev.artemsem.voxflow` / `mcp-token` (design ST-06).
struct KeychainTokenStore: TokenStoring {
    let service = "dev.artemsem.voxflow"
    let account = "mcp-token"

    func read() throws -> String? { try KeychainString.read(service: service, account: account) }
    func write(_ token: String) throws { try KeychainString.write(token, service: service, account: account) }
}

/// Settings › MCP Server (design ST-06, ST-06r) — UI only this phase (ruling 5): no server actually
/// listens yet, but the toggle/token/tool choices persist so the real server (phase 6) has
/// something to read. `enabled` defaults to **off** — the canvas mock shows it on, but that would
/// claim a server is running when none is; the view shows a "Server arrives in a later release."
/// footnote alongside the toggle instead.
@Observable @MainActor
final class MCPSettings {
    private let store: any KeyValueStore
    private let tokenStore: any TokenStoring
    /// M1: `token`'s getter writes this lazily on first read, including from inside a SwiftUI
    /// `body` (`MCPSettingsView` reads `mcp.maskedToken`) — without `@ObservationIgnored`, that
    /// first render mutates `@Observable`-tracked state mid-update. Nothing outside `token`/
    /// `maskedToken`/`regenerate()` needs this to be observed; those already publish through
    /// `token`'s return value.
    @ObservationIgnored private var cachedToken: String?

    enum Keys {
        static let enabled = "mcp.enabled"
        static let toolTranscribeFile = "mcp.tool.transcribeFile"
        static let toolDictate = "mcp.tool.dictate"
        static let toolSearchHistory = "mcp.tool.searchHistory"
    }

    var enabled: Bool { didSet { store.set(enabled ? "1" : "0", forKey: Keys.enabled) } }
    var toolTranscribeFile: Bool { didSet { store.set(toolTranscribeFile ? "1" : "0", forKey: Keys.toolTranscribeFile) } }
    var toolDictate: Bool { didSet { store.set(toolDictate ? "1" : "0", forKey: Keys.toolDictate) } }
    var toolSearchHistory: Bool { didSet { store.set(toolSearchHistory ? "1" : "0", forKey: Keys.toolSearchHistory) } }

    init(store: any KeyValueStore, token: any TokenStoring) {
        self.store = store
        tokenStore = token
        enabled = store.string(forKey: Keys.enabled) == "1"                             // default off
        toolTranscribeFile = store.string(forKey: Keys.toolTranscribeFile) != "0"        // default on
        toolDictate = store.string(forKey: Keys.toolDictate) != "0"                      // default on
        toolSearchHistory = store.string(forKey: Keys.toolSearchHistory) == "1"          // default off
    }

    /// Created on first read (32 lowercase hex characters behind `vf_`), then cached — a repeat
    /// read never re-generates. If the Keychain write fails, the generated token is still handed
    /// back (and cached) so the UI has something to show; it just won't survive a relaunch, which
    /// is a Keychain problem to surface elsewhere, not a reason to break this read.
    var token: String {
        if let cachedToken { return cachedToken }
        if let stored = (try? tokenStore.read()) ?? nil, !stored.isEmpty {
            cachedToken = stored
            return stored
        }
        let generated = Self.generateToken()
        try? tokenStore.write(generated)
        cachedToken = generated
        return generated
    }

    /// ST-06 masked display: `vf_` + 12 bullets + the last 4 characters.
    var maskedToken: String {
        let value = token
        return "vf_" + String(repeating: "•", count: 12) + value.suffix(4)
    }

    /// ST-06r "Regenerate and copy" — a fresh token, written through (best-effort, same reasoning
    /// as `token`'s getter) and returned so the caller can put it on the clipboard.
    @discardableResult
    func regenerate() -> String {
        let generated = Self.generateToken()
        try? tokenStore.write(generated)
        cachedToken = generated
        return generated
    }

    private static func generateToken() -> String {
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        return "vf_" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}
