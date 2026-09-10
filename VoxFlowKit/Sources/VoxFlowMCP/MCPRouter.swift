import Foundation

/// Per-request routing inputs the transport supplies: which tools this VoxFlow install has
/// enabled, and the server's own version string (for `serverInfo`).
public struct MCPRequestContext: Sendable, Equatable {
    public var enabledTools: Set<MCPToolID>
    public var serverVersion: String

    public init(enabledTools: Set<MCPToolID>, serverVersion: String) {
        self.enabledTools = enabledTools
        self.serverVersion = serverVersion
    }
}

/// What the transport must do with a routed request. `callTool` is the only case that needs the
/// app.
public enum MCPRouted: Sendable, Equatable {
    case result(JSONValue) // answer verbatim
    case accepted // 202, no body (a notification)
    case callTool(MCPToolID, arguments: JSONValue, id: JSONRPCID?)
    case failure(MCPError, id: JSONRPCID?)
}

/// Answers both protocol eras: `server/discover` + per-request `_meta` (modern), and
/// `initialize` → `notifications/initialized` → `tools/list`/`tools/call` (legacy). Pure —
/// no I/O, no sockets; the transport supplies the parsed request and gets back what to do.
public struct MCPRouter: Sendable {
    public init() {}

    public func route(_ request: JSONRPCRequest, context: MCPRequestContext) -> MCPRouted {
        switch request.method {
        case "server/discover":
            return .result(discoverResult(context: context))
        case "initialize":
            return .result(initializeResult(request, context: context))
        case "notifications/initialized":
            return .accepted
        case "tools/list":
            return .result(toolsListResult(context: context))
        case "tools/call":
            return routeToolsCall(request, context: context)
        default:
            return .failure(.methodNotFound, id: request.id)
        }
    }

    private func discoverResult(context: MCPRequestContext) -> JSONValue {
        let identity = ServerIdentity(version: context.serverVersion)
        return .object([
            "resultType": .string("complete"),
            "supportedVersions": .array(MCPProtocolVersion.supported.map(JSONValue.string)),
            "capabilities": .object(["tools": .object([:])]),
            "_meta": .object([
                MCPMetaKey.serverInfo: .object([
                    "name": .string(identity.name),
                    "version": .string(identity.version),
                ]),
            ]),
        ])
    }

    private func initializeResult(_ request: JSONRPCRequest, context: MCPRequestContext) -> JSONValue {
        let identity = ServerIdentity(version: context.serverVersion)
        let requested = request.params?["protocolVersion"]?.stringValue
        let version = requested.flatMap { MCPProtocolVersion.supported.contains($0) ? $0 : nil } ?? MCPProtocolVersion.legacy
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object([
                "name": .string(identity.name),
                "version": .string(identity.version),
            ]),
        ])
    }

    private func toolsListResult(context: MCPRequestContext) -> JSONValue {
        let tools = MCPToolID.allCases
            .filter { context.enabledTools.contains($0) }
            .map { toolID -> JSONValue in
                let descriptor = toolID.descriptor
                return .object([
                    "name": .string(descriptor.name),
                    "description": .string(descriptor.description),
                    "inputSchema": descriptor.inputSchema,
                ])
            }
        return .object(["tools": .array(tools)])
    }

    private func routeToolsCall(_ request: JSONRPCRequest, context: MCPRequestContext) -> MCPRouted {
        guard
            let toolName = request.params?["name"]?.stringValue,
            let toolID = MCPToolID(toolName: toolName),
            context.enabledTools.contains(toolID)
        else {
            return .failure(.methodNotFound, id: request.id)
        }
        let arguments = request.params?["arguments"] ?? .object([:])
        return .callTool(toolID, arguments: arguments, id: request.id)
    }
}
