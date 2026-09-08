import Testing
@testable import VoxFlowDictation
import VoxFlowCore

@Suite("VoxFlowDictation module")
struct DictationModuleTests {
    @Test("module links against VoxFlowCore")
    func linksCore() {
        #expect(DictationModule.name == "VoxFlowDictation")
        #expect(DictationModule.coreVersion == VoxFlowVersion.string)
    }
}
