import Foundation
import Testing
@testable import VoxFlowMCP

@Suite("MCP stdio framing")
struct MCPStdioTests {
    @Test func fragmentedUnicodeAndCRLF() throws {
        var parser = MCPStdioFramer()
        let message = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"echo👋\"}"
        var frames: [Data] = []
        for byte in (message + "\r\n\n").utf8 {
            if let frame = try parser.append(byte) { frames.append(frame) }
        }
        #expect(frames == [Data(message.utf8)])
        #expect(try MCPStdioFramer.request(frames[0]).method == "echo👋")
    }

    @Test func capsIncompleteLines() throws {
        var parser = MCPStdioFramer(maximumBytes: 3)
        for byte in "abc".utf8 { _ = try parser.append(byte) }
        #expect(throws: MCPStdioFramer.Failure.tooLarge) { try parser.append(100) }
    }

    @Test(arguments: ["[]", "null", "{\"method\":\"initialize\",\"id\":1}",
                      "{\"jsonrpc\":\"1.0\",\"method\":\"initialize\",\"id\":1}"])
    func rejectsInvalidEnvelope(_ json: String) {
        #expect(throws: (any Error).self) { try MCPStdioFramer.request(Data(json.utf8)) }
    }

    @Test(arguments: ["[]", "null", "{\"jsonrpc\":\"2.0\"}",
                      "{\"jsonrpc\":\"2.0\",\"method\":1}"])
    func validJSONWithInvalidEnvelopeReturnsInvalidRequest(_ json: String) {
        do {
            _ = try MCPStdioFramer.request(Data(json.utf8))
            Issue.record("Invalid envelope accepted")
        } catch {
            let response = MCPStdioFramer.errorResponse(for: error)
            #expect(response["id"] == .null)
            #expect(response["error"]?["code"]?.intValue == -32600)
        }
    }

    @Test func malformedJSONReturnsParseError() {
        do {
            _ = try MCPStdioFramer.request(Data("{broken}".utf8))
            Issue.record("Malformed JSON accepted")
        } catch {
            let response = MCPStdioFramer.errorResponse(for: error)
            #expect(response["id"] == .null)
            #expect(response["error"]?["code"]?.intValue == -32700)
        }
    }

    @Test func pingIsTransportIndependent() {
        #expect(MCPRouter().route(JSONRPCRequest(id: .number(1), method: "ping"),
            context: MCPRequestContext(enabledTools: [], serverVersion: "2.1.0")) == .result(.object([:])))
    }
}
