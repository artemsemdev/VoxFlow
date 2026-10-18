import Foundation

/// The MCP protocol revisions VoxFlow speaks. `current` is the modern, per-request-`_meta` era;
/// `legacy` is the `initialize`-handshake era real clients (Cursor, `mcp-remote`) send today.
public enum MCPProtocolVersion {
    public static let current = "2026-07-28"
    public static let legacy = "2025-06-18"
    public static let supported = [current, legacy]
}

/// The identity VoxFlow reports to clients in `server/discover` and `initialize` results.
public struct ServerIdentity: Sendable, Equatable {
    public var name: String
    public var version: String

    public init(name: String = "VoxFlow", version: String) {
        self.name = name
        self.version = version
    }
}

/// `_meta` object keys used by the modern (`2026-07-28`) protocol era.
public enum MCPMetaKey {
    public static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
    public static let clientInfo = "io.modelcontextprotocol/clientInfo"
    public static let serverInfo = "io.modelcontextprotocol/serverInfo"
}
