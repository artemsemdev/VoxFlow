import Foundation

/// Bounded newline-delimited UTF-8 JSON-RPC; no I/O or transport-specific authorization.
public struct MCPStdioFramer: Sendable {
    public enum Failure: Error { case tooLarge, invalidEnvelope }
    private var pending = Data()
    private let maximumBytes: Int

    public init(maximumBytes: Int = 1_048_576) { self.maximumBytes = maximumBytes }

    public mutating func append(_ byte: UInt8) throws -> Data? {
        if byte == 10 {
            var frame = pending
            pending.removeAll(keepingCapacity: true)
            if frame.last == 13 { frame.removeLast() }
            return frame.isEmpty ? nil : frame
        }
        guard pending.count < maximumBytes else { throw Failure.tooLarge }
        pending.append(byte)
        return nil
    }

    public static func request(_ data: Data) throws -> JSONRPCRequest {
        let tree = try JSONDecoder().decode(JSONValue.self, from: data)
        guard tree["jsonrpc"]?.stringValue == "2.0", tree.objectValue != nil else {
            throw Failure.invalidEnvelope
        }
        do { return try JSONDecoder().decode(JSONRPCRequest.self, from: data) }
        catch { throw Failure.invalidEnvelope }
    }

    public static func errorResponse(for error: any Error) -> JSONValue {
        let invalidRequest = if case Failure.invalidEnvelope = error { true } else { false }
        return .object([
            "jsonrpc": .string("2.0"), "id": .null,
            "error": .object(["code": .int(invalidRequest ? -32600 : -32700),
                              "message": .string(invalidRequest ? "Invalid Request" : "Parse error")])
        ])
    }

}
