import Testing
@testable import VoxFlowMCP
import VoxFlowCore

@Suite("VoxFlowMCP module")
struct MCPModuleTests {
    @Test("module links against VoxFlowCore")
    func linksCore() {
        #expect(MCPModule.name == "VoxFlowMCP")
        #expect(MCPModule.coreVersion == VoxFlowVersion.string)
    }
}
