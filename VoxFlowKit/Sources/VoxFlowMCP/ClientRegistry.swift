import Foundation

/// One process that has connected to the loopback MCP server, as resolved via `libproc` (the app's
/// `PeerResolving`). `name` is the empty string only when resolution failed entirely (the caller
/// substitutes display copy like "Unknown app"); `path` is `""` when `proc_pidpath` failed but the
/// name still resolved.
public struct MCPClientIdentity: Sendable, Hashable {
    public var name: String
    public var path: String
    public var pid: Int32?

    public init(name: String, path: String, pid: Int32?) {
        self.name = name
        self.path = path
        self.pid = pid
    }
}

/// What to do with a connecting client: let it through, refuse it outright, or show the ST-06a
/// approval dialog. `ClientRegistry.decision(for:...)` (persisted-state lookup) only ever returns
/// `.allow`/`.deny`/`.ask`; `.allowOnce` is a human's live answer from the approval presenter
/// (`MCPApprovalPresenting.present`, Task 3) — plan ruling 5, amended in the Task 3 review: the
/// seam sees a client identity, not a TCP connection, so `Allow once` is scoped to the rest of the
/// app session and is never persisted to `mcp_clients`.
public enum MCPClientDecision: Sendable, Equatable {
    case allow
    case allowOnce
    case deny
    case ask
}

/// Pure decision rules over injected state (ruling 5/6): no I/O, no persistence — the caller reads
/// `mcp_clients` (via `MCPClientStore`) and session sets, and supplies them here.
public struct ClientRegistry: Sendable {
    public init() {}

    /// `deniedThisSession` is checked first: a session-scoped "no" overrides a persisted approval,
    /// since it's the most recent, explicit signal. Otherwise a persisted approval or a one-time
    /// "allow once" both let the request through; anything else needs the approval dialog.
    public func decision(
        for identity: MCPClientIdentity,
        approved: Set<String>,
        deniedThisSession: Set<String>,
        allowedOnce: Set<String>
    ) -> MCPClientDecision {
        let key = Self.key(identity)
        if deniedThisSession.contains(key) { return .deny }
        if approved.contains(key) || allowedOnce.contains(key) { return .allow }
        return .ask
    }

    /// The key both this registry and `mcp_clients` use — name + path, never the pid (ruling 5): a
    /// relaunched client gets a new pid every time, but the same name+path should keep its
    /// approval.
    public static func key(_ identity: MCPClientIdentity) -> String {
        "\(identity.name)\u{0}\(identity.path)"
    }
}
