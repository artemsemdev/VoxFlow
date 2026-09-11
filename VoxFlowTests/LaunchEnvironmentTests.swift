import Testing
@testable import VoxFlow

@Suite("LaunchEnvironment")
struct LaunchEnvironmentTests {
    @Test("XCTestConfigurationFilePath present means running under tests")
    func detectsTestHost() {
        #expect(LaunchEnvironment.isRunningTests(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
    }

    @Test("scheme test flag identifies the host before XCTest initializes")
    func detectsSchemeTestHost() {
        #expect(LaunchEnvironment.isRunningTests(environment: ["VOXFLOW_TEST_HOST": "1"]))
        #expect(!LaunchEnvironment.isRunningTests(environment: ["VOXFLOW_TEST_HOST": "0"]))
    }

    @Test("XCTest bundle and injection markers also identify hosted tests", arguments: ["XCTestBundlePath", "XCInjectBundleInto"])
    func detectsOtherTestMarkers(_ marker: String) {
        #expect(LaunchEnvironment.isRunningTests(environment: [marker: "/tmp/VoxFlowTests.xctest"]))
    }

    @Test("the actual test process must select the isolated startup path")
    func actualTestHost() {
        #expect(LaunchEnvironment.isRunningTests())
    }

    @Test("no XCTestConfigurationFilePath means a normal launch")
    func detectsNormalLaunch() {
        #expect(LaunchEnvironment.isRunningTests(environment: [:]) == false)
        #expect(LaunchEnvironment.isRunningTests(environment: ["PATH": "/usr/bin"]) == false)
    }
}
