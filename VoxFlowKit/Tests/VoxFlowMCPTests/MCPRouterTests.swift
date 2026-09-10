import Testing
@testable import VoxFlowMCP

@Suite("MCPRouter")
struct MCPRouterTests {
    private let router = MCPRouter()

    private func context(enabled: Set<MCPToolID> = [.transcribeFile, .dictate, .searchHistory]) -> MCPRequestContext {
        MCPRequestContext(enabledTools: enabled, serverVersion: "2.1.0")
    }

    @Test("server/discover lists both protocol versions, a tools capability, and server identity")
    func serverDiscover() {
        let request = JSONRPCRequest(id: .number(1), method: "server/discover")
        guard case .result(let value) = router.route(request, context: context()) else {
            Issue.record("expected .result")
            return
        }
        let versions = value["supportedVersions"]?.arrayValue?.compactMap { $0.stringValue }
        #expect(versions == [MCPProtocolVersion.current, MCPProtocolVersion.legacy])
        #expect(value["resultType"]?.stringValue == "complete")
        #expect(value["capabilities"]?["tools"] != nil)
        #expect(value["_meta"]?[MCPMetaKey.serverInfo]?["name"]?.stringValue == "VoxFlow")
    }

    @Test("initialize echoes a supported client protocolVersion")
    func initializeEchoesSupportedVersion() {
        let params = JSONValue.object(["protocolVersion": .string(MCPProtocolVersion.legacy)])
        let request = JSONRPCRequest(id: .number(1), method: "initialize", params: params)
        guard case .result(let value) = router.route(request, context: context()) else {
            Issue.record("expected .result")
            return
        }
        #expect(value["protocolVersion"]?.stringValue == MCPProtocolVersion.legacy)
        #expect(value["capabilities"]?["tools"] != nil)
        #expect(value["serverInfo"]?["name"]?.stringValue == "VoxFlow")
    }

    @Test("initialize with an unsupported protocolVersion still answers legacy — rejection is the policy's job")
    func initializeUnsupportedVersionFallsBackToLegacy() {
        let params = JSONValue.object(["protocolVersion": .string("1999-01-01")])
        let request = JSONRPCRequest(id: .number(1), method: "initialize", params: params)
        guard case .result(let value) = router.route(request, context: context()) else {
            Issue.record("expected .result")
            return
        }
        #expect(value["protocolVersion"]?.stringValue == MCPProtocolVersion.legacy)
    }

    @Test("tools/list returns exactly the enabled tools")
    func toolsListOnlyEnabled() {
        let request = JSONRPCRequest(id: .number(1), method: "tools/list")
        guard case .result(let value) = router.route(request, context: context(enabled: [.transcribeFile])) else {
            Issue.record("expected .result")
            return
        }
        let tools = value["tools"]?.arrayValue ?? []
        #expect(tools.count == 1)
        #expect(tools.first?["name"]?.stringValue == "transcribe_file")
        #expect(tools.first?["description"]?.stringValue == "Transcribe an audio file at a path; returns text or SRT")
        let required = tools.first?["inputSchema"]?["required"]?.arrayValue?.compactMap { $0.stringValue }
        #expect(required == ["path"])
    }

    @Test("tools/call for a disabled tool fails with methodNotFound")
    func toolsCallDisabledTool() {
        let params = JSONValue.object(["name": .string("dictate"), "arguments": .object([:])])
        let request = JSONRPCRequest(id: .number(5), method: "tools/call", params: params)
        let routed = router.route(request, context: context(enabled: [.transcribeFile]))
        #expect(routed == .failure(.methodNotFound, id: .number(5)))
    }

    @Test("tools/call for an unknown tool name fails with methodNotFound")
    func toolsCallUnknownToolName() {
        let params = JSONValue.object(["name": .string("nope"), "arguments": .object([:])])
        let request = JSONRPCRequest(id: .number(5), method: "tools/call", params: params)
        let routed = router.route(request, context: context())
        #expect(routed == .failure(.methodNotFound, id: .number(5)))
    }

    @Test("tools/call for an enabled tool passes the arguments through")
    func toolsCallEnabledTool() {
        let arguments = JSONValue.object(["path": .string("/tmp/a.wav")])
        let params = JSONValue.object(["name": .string("transcribe_file"), "arguments": arguments])
        let request = JSONRPCRequest(id: .number(5), method: "tools/call", params: params)
        let routed = router.route(request, context: context(enabled: [.transcribeFile]))
        #expect(routed == .callTool(.transcribeFile, arguments: arguments, id: .number(5)))
    }

    @Test("notifications/initialized is accepted with no body")
    func notificationsInitialized() {
        let request = JSONRPCRequest(method: "notifications/initialized")
        #expect(router.route(request, context: context()) == .accepted)
    }

    @Test("an unknown method fails with methodNotFound")
    func unknownMethod() {
        let request = JSONRPCRequest(id: .number(9), method: "nope/nope")
        #expect(router.route(request, context: context()) == .failure(.methodNotFound, id: .number(9)))
    }
}
