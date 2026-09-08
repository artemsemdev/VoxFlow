import Testing
@testable import VoxFlowCore

@Suite("VoxFlowVersion")
struct VersionTests {
    @Test("version string is semver, optionally with a pre-release suffix")
    func versionIsSemver() {
        let parts = VoxFlowVersion.string.split(separator: "-", maxSplits: 1)
        #expect((1...2).contains(parts.count))
        let numbers = parts[0].split(separator: ".")
        #expect(numbers.count == 3)
        #expect(numbers.allSatisfy { Int($0) != nil })
    }
}
