import Testing
@testable import VoxFlowStyling
import VoxFlowCore

@Suite("VoxFlowStyling module")
struct StylingModuleTests {
    @Test("module links against VoxFlowCore")
    func linksCore() {
        #expect(StylingModule.name == "VoxFlowStyling")
        #expect(StylingModule.coreVersion == VoxFlowVersion.string)
    }
}
