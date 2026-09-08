import Testing
@testable import VoxFlowStorage
import VoxFlowCore

@Suite("VoxFlowStorage module")
struct StorageModuleTests {
    @Test("module links against VoxFlowCore")
    func linksCore() {
        #expect(StorageModule.name == "VoxFlowStorage")
        #expect(StorageModule.coreVersion == VoxFlowVersion.string)
    }
}
