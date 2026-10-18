import Foundation

/// One HTTP POST to the MCP endpoint. `headers` keys are already lowercased by the caller (the
/// transport lowercases them before constructing this).
public struct MCPHTTPRequest: Sendable, Equatable {
    public var method: String // "POST"
    public var path: String
    public var headers: [String: String] // lowercased keys
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

/// What the transport does after validation: hand the parsed request to the router, or answer
/// an HTTP status directly (with an optional JSON-RPC error body).
public enum MCPHTTPVerdict: Sendable, Equatable {
    case proceed(JSONRPCRequest)
    case status(Int, JSONRPCError?) // 401/403/404/405/400 with an optional JSON-RPC body
}

/// Pure validation the transport applies before routing: path, method, `Origin`, bearer token,
/// body parse, and (for the modern protocol era) header/body agreement and version support.
/// No sockets, no side effects.
public struct MCPHTTPPolicy: Sendable {
    private let endpointPath: String

    public init(endpointPath: String = "/mcp") {
        self.endpointPath = endpointPath
    }

    /// `token` is compared in constant time; `boundPort` is used to accept
    /// `http://127.0.0.1:<port>`/`http://localhost:<port>` origins.
    public func verdict(for request: MCPHTTPRequest, token: String, boundPort: UInt16) -> MCPHTTPVerdict {
        guard request.path == endpointPath else {
            return .status(404, nil)
        }
        guard request.method == "POST" else {
            return .status(405, nil)
        }
        guard isOriginAllowed(request.headers["origin"], boundPort: boundPort) else {
            return .status(403, nil)
        }
        guard isAuthorized(request.headers, token: token) else {
            return .status(401, nil)
        }
        guard let rpcRequest = try? JSONDecoder().decode(JSONRPCRequest.self, from: request.body) else {
            return .status(400, MCPError.parse.jsonRPCError())
        }
        if let versionError = modernEraViolation(for: rpcRequest, headers: request.headers) {
            return .status(400, versionError.jsonRPCError())
        }
        return .proceed(rpcRequest)
    }

    /// `nil` when the request is either a legacy request (no `_meta` version — the modern-era
    /// checks don't apply) or a modern request whose headers agree with the body and whose
    /// version is supported.
    private func modernEraViolation(for request: JSONRPCRequest, headers: [String: String]) -> MCPError? {
        guard let metaVersion = request.params?["_meta"]?[MCPMetaKey.protocolVersion]?.stringValue else {
            return nil // legacy request: no modern-era headers required.
        }
        guard headers["mcp-protocol-version"] == metaVersion else {
            return .headerMismatch
        }
        guard headers["mcp-method"] == request.method else {
            return .headerMismatch
        }
        if request.method == "tools/call" {
            let paramsName = request.params?["name"]?.stringValue
            guard headers["mcp-name"] == paramsName else {
                return .headerMismatch
            }
        }
        guard MCPProtocolVersion.supported.contains(metaVersion) else {
            return .unsupportedProtocolVersion(supported: MCPProtocolVersion.supported)
        }
        return nil
    }

    private func isOriginAllowed(_ origin: String?, boundPort: UInt16) -> Bool {
        guard let origin else { return true } // absent Origin: fine (non-browser clients).
        let allowed: Set<String> = [
            "http://127.0.0.1",
            "http://127.0.0.1:\(boundPort)",
            "http://localhost",
            "http://localhost:\(boundPort)",
        ]
        return allowed.contains(origin)
    }

    private func isAuthorized(_ headers: [String: String], token: String) -> Bool {
        guard let authorization = headers["authorization"], authorization.hasPrefix("Bearer ") else {
            return false
        }
        let provided = String(authorization.dropFirst("Bearer ".count))
        return constantTimeEquals(provided, token)
    }
}
