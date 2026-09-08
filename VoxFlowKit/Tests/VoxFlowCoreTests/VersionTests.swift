import Testing
@testable import VoxFlowCore

@Suite("VoxFlowVersion")
struct VersionTests {
    @Test("version string is semver with a -dev suffix until the first release")
    func versionIsDevSemver() {
        let parts = VoxFlowVersion.string.split(separator: "-", maxSplits: 1)
        #expect(parts.count == 2)
        #expect(parts[1] == "dev")
        let numbers = parts[0].split(separator: ".")
        #expect(numbers.count == 3)
        #expect(numbers.allSatisfy { Int($0) != nil })
    }
}
