import Foundation

/// The MCP server's error table: a JSON-RPC `code` plus the HTTP status the transport answers
/// with. Most JSON-RPC errors ride inside a `200` body (the HTTP layer succeeded, the RPC call
/// didn't); a handful of errors are HTTP-level failures and get their own status.
///
/// `unsupportedProtocolVersion` is not a numeric code of its own in the wire protocol — it is a
/// JSON-RPC error (`UnsupportedProtocolVersionError`) whose `data` carries
/// `{"supported": [...]}`. It is modeled here with code `-32000` and HTTP `400`.
public enum MCPError: Sendable, Equatable, Error {
    case parse
    case invalidRequest
    case methodNotFound
    case invalidParams
    case internalError
    case headerMismatch
    case unauthorized
    case busy
    case timedOut
    case historyUnavailable
    /// A `dictate` capture reached a terminal state without producing a result (Escape, a
    /// transcription failure, an empty transcript, no microphone, an excluded app, no model
    /// installed) — the tool fails fast with the state's own readable reason instead of holding the
    /// caller for the full timeout budget (Task 3 review item 6).
    case captureFailed
    case unsupportedProtocolVersion(supported: [String])

    public var code: Int {
        switch self {
        case .parse: return -32700
        case .invalidRequest: return -32600
        case .methodNotFound: return -32601
        case .invalidParams: return -32602
        case .internalError: return -32603
        case .headerMismatch: return -32020
        case .unauthorized: return -32001
        case .busy: return -32002
        case .timedOut: return -32003
        case .historyUnavailable: return -32004
        case .captureFailed: return -32005
        case .unsupportedProtocolVersion: return -32000
        }
    }

    public var message: String {
        switch self {
        case .parse: return "Parse error"
        case .invalidRequest: return "Invalid Request"
        case .methodNotFound: return "Method not found"
        case .invalidParams: return "Invalid params"
        case .internalError: return "Internal error"
        case .headerMismatch: return "Header mismatch"
        case .unauthorized: return "Unauthorized"
        case .busy: return "Server busy"
        case .timedOut: return "Timed out"
        case .historyUnavailable: return "History unavailable"
        case .captureFailed: return "Capture failed"
        case .unsupportedProtocolVersion: return "Unsupported protocol version"
        }
    }

    /// `methodNotFound` → `404` (the transport treats an unknown RPC method like an unknown
    /// route); `headerMismatch`/`unsupportedProtocolVersion` → `400` (a malformed handshake);
    /// `unauthorized` → `401`; everything else answers `200` with a JSON-RPC error body — the
    /// HTTP request succeeded, the call itself failed.
    public var httpStatus: Int {
        switch self {
        case .methodNotFound: return 404
        case .headerMismatch, .unsupportedProtocolVersion: return 400
        case .unauthorized: return 401
        default: return 200
        }
    }

    /// The `data` payload carried on the wire — only `unsupportedProtocolVersion` has one.
    public var data: JSONValue? {
        switch self {
        case .unsupportedProtocolVersion(let supported):
            return .object(["supported": .array(supported.map(JSONValue.string))])
        default:
            return nil
        }
    }

    /// Renders this error as the JSON-RPC error object the wire format expects.
    public func jsonRPCError() -> JSONRPCError {
        JSONRPCError(code: code, message: message, data: data)
    }
}
