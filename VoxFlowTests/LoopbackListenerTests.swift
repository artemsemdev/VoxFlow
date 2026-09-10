import Testing
@testable import VoxFlow

/// `LoopbackListener` itself is exercised only by the Task 5 integration test (it opens a real
/// socket); here we only assert the transport-level error copy, which is pure.
@Suite("MCPServerError")
struct MCPServerErrorTests {
    @Test("noFreePort's message names the port range")
    func noFreePortMessage() {
        #expect(MCPServerError.noFreePort.message == "VoxFlow couldn't find a free port for the MCP server (7331–7340 are all in use).")
    }
}
