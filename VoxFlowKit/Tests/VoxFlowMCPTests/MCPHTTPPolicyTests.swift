import Foundation
import Testing
@testable import VoxFlowMCP

@Suite("MCPHTTPPolicy")
struct MCPHTTPPolicyTests {
    private let policy = MCPHTTPPolicy()
    private let token = "vf_test_token"
    private let boundPort: UInt16 = 7333

    private func legacyInitializeBody() -> Data {
        Data(#"{"id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#.utf8)
    }

    private func modernBody(version: String, method: String, name: String? = nil) -> Data {
        var params = "\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"\(version)\"}"
        if let name {
            params += ",\"name\":\"\(name)\""
        }
        let json = #"{"id":1,"method":"\#(method)","params":{\#(params)}}"#
        return Data(json.utf8)
    }

    private func request(
        method: String = "POST",
        path: String = "/mcp",
        headers: [String: String] = [:],
        body: Data
    ) -> MCPHTTPRequest {
        MCPHTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func authorizedHeaders(_ extra: [String: String] = [:]) -> [String: String] {
        var headers = ["authorization": "Bearer \(token)"]
        for (key, value) in extra { headers[key] = value }
        return headers
    }

    @Test("GET /mcp is rejected with 405")
    func getRejected() {
        let verdict = policy.verdict(
            for: request(method: "GET", headers: authorizedHeaders(), body: legacyInitializeBody()),
            token: token, boundPort: boundPort
        )
        #expect(verdict == .status(405, nil))
    }

    @Test("DELETE /mcp is rejected with 405")
    func deleteRejected() {
        let verdict = policy.verdict(
            for: request(method: "DELETE", headers: authorizedHeaders(), body: legacyInitializeBody()),
            token: token, boundPort: boundPort
        )
        #expect(verdict == .status(405, nil))
    }

    @Test("POST to an unknown path is rejected with 404")
    func unknownPathRejected() {
        let verdict = policy.verdict(
            for: request(path: "/nope", headers: authorizedHeaders(), body: legacyInitializeBody()),
            token: token, boundPort: boundPort
        )
        #expect(verdict == .status(404, nil))
    }

    @Test("a disallowed Origin is rejected with 403")
    func disallowedOriginRejected() {
        let verdict = policy.verdict(
            for: request(headers: authorizedHeaders(["origin": "https://evil.example"]), body: legacyInitializeBody()),
            token: token, boundPort: boundPort
        )
        #expect(verdict == .status(403, nil))
    }

    @Test("a loopback Origin at the bound port is allowed")
    func loopbackOriginAtBoundPortAllowed() {
        let verdict = policy.verdict(
            for: request(headers: authorizedHeaders(["origin": "http://127.0.0.1:\(boundPort)"]), body: legacyInitializeBody()),
            token: token, boundPort: boundPort
        )
        guard case .proceed = verdict else {
            Issue.record("expected .proceed, got \(verdict)")
            return
        }
    }

    @Test("a loopback Origin at a different port than boundPort is rejected")
    func loopbackOriginWrongPortRejected() {
        let verdict = policy.verdict(
            for: request(headers: authorizedHeaders(["origin": "http://127.0.0.1:9999"]), body: legacyInitializeBody()),
            token: token, boundPort: boundPort
        )
        #expect(verdict == .status(403, nil))
    }

    @Test("a missing Authorization header is rejected with 401")
    func missingAuthorizationRejected() {
        let verdict = policy.verdict(
            for: request(headers: [:], body: legacyInitializeBody()),
            token: token, boundPort: boundPort
        )
        #expect(verdict == .status(401, nil))
    }

    @Test("a wrong bearer token is rejected with 401")
    func wrongTokenRejected() {
        let verdict = policy.verdict(
            for: request(headers: ["authorization": "Bearer wrong"], body: legacyInitializeBody()),
            token: token, boundPort: boundPort
        )
        #expect(verdict == .status(401, nil))
    }

    @Test("the correct bearer token proceeds")
    func correctTokenProceeds() {
        let verdict = policy.verdict(
            for: request(headers: authorizedHeaders(), body: legacyInitializeBody()),
            token: token, boundPort: boundPort
        )
        guard case .proceed = verdict else {
            Issue.record("expected .proceed, got \(verdict)")
            return
        }
    }

    @Test("an unparseable body is rejected with 400 and a parse error")
    func unparseableBodyRejected() {
        let verdict = policy.verdict(
            for: request(headers: authorizedHeaders(), body: Data("not json".utf8)),
            token: token, boundPort: boundPort
        )
        #expect(verdict == .status(400, JSONRPCError(code: -32700, message: MCPError.parse.message)))
    }

    @Test("a modern request whose MCP-Protocol-Version header disagrees with the body's _meta version is rejected")
    func headerVersionMismatchRejected() {
        let headers = authorizedHeaders(["mcp-protocol-version": MCPProtocolVersion.legacy, "mcp-method": "tools/list"])
        let body = modernBody(version: MCPProtocolVersion.current, method: "tools/list")
        let verdict = policy.verdict(for: request(headers: headers, body: body), token: token, boundPort: boundPort)
        #expect(verdict == .status(400, JSONRPCError(code: -32020, message: MCPError.headerMismatch.message)))
    }

    @Test("a modern request with matching MCP-Protocol-Version and Mcp-Method headers proceeds")
    func matchingHeadersProceed() {
        let headers = authorizedHeaders(["mcp-protocol-version": MCPProtocolVersion.current, "mcp-method": "tools/list"])
        let body = modernBody(version: MCPProtocolVersion.current, method: "tools/list")
        let verdict = policy.verdict(for: request(headers: headers, body: body), token: token, boundPort: boundPort)
        guard case .proceed = verdict else {
            Issue.record("expected .proceed, got \(verdict)")
            return
        }
    }

    @Test("a tools/call body whose Mcp-Name header disagrees with params.name is rejected")
    func mcpNameMismatchRejected() {
        let headers = authorizedHeaders([
            "mcp-protocol-version": MCPProtocolVersion.current,
            "mcp-method": "tools/call",
            "mcp-name": "dictate",
        ])
        let body = modernBody(version: MCPProtocolVersion.current, method: "tools/call", name: "transcribe_file")
        let verdict = policy.verdict(for: request(headers: headers, body: body), token: token, boundPort: boundPort)
        #expect(verdict == .status(400, JSONRPCError(code: -32020, message: MCPError.headerMismatch.message)))
    }

    @Test("a tools/call body whose Mcp-Name header agrees with params.name proceeds")
    func mcpNameAgreementProceeds() {
        let headers = authorizedHeaders([
            "mcp-protocol-version": MCPProtocolVersion.current,
            "mcp-method": "tools/call",
            "mcp-name": "transcribe_file",
        ])
        let body = modernBody(version: MCPProtocolVersion.current, method: "tools/call", name: "transcribe_file")
        let verdict = policy.verdict(for: request(headers: headers, body: body), token: token, boundPort: boundPort)
        guard case .proceed = verdict else {
            Issue.record("expected .proceed, got \(verdict)")
            return
        }
    }

    @Test("an unsupported _meta protocol version is rejected naming both supported versions")
    func unsupportedVersionRejected() {
        let headers = authorizedHeaders(["mcp-protocol-version": "1999-01-01", "mcp-method": "tools/list"])
        let body = modernBody(version: "1999-01-01", method: "tools/list")
        let verdict = policy.verdict(for: request(headers: headers, body: body), token: token, boundPort: boundPort)
        guard case .status(400, let error) = verdict else {
            Issue.record("expected .status(400, _), got \(verdict)")
            return
        }
        #expect(error?.code == -32000)
        let supported = error?.data?["supported"]?.arrayValue?.compactMap { $0.stringValue }
        #expect(supported == MCPProtocolVersion.supported)
    }

    @Test("a legacy body with no _meta and no MCP headers proceeds")
    func legacyBodyProceeds() {
        let verdict = policy.verdict(
            for: request(headers: authorizedHeaders(), body: legacyInitializeBody()),
            token: token, boundPort: boundPort
        )
        guard case .proceed = verdict else {
            Issue.record("expected .proceed, got \(verdict)")
            return
        }
    }
}

@Suite("constantTimeEquals")
struct ConstantTimeEqualsTests {
    @Test("equal strings compare true")
    func equalStrings() {
        #expect(constantTimeEquals("vf_secret", "vf_secret"))
    }

    @Test("a prefix of a longer string compares false")
    func prefixMismatch() {
        #expect(!constantTimeEquals("vf_a", "vf_ab"))
    }

    @Test("different strings of the same length compare false")
    func differentStringsSameLength() {
        #expect(!constantTimeEquals("vf_aaaa", "vf_bbbb"))
    }

    @Test("empty strings compare true")
    func emptyStringsEqual() {
        #expect(constantTimeEquals("", ""))
    }
}
