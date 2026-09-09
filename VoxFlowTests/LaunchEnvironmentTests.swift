import Testing
@testable import VoxFlow

@Suite("LaunchEnvironment")
struct LaunchEnvironmentTests {
    @Test("XCTestConfigurationFilePath present means running under tests")
    func detectsTestHost() {
        #expect(LaunchEnvironment.isRunningTests(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
    }

    @Test("no XCTestConfigurationFilePath means a normal launch")
    func detectsNormalLaunch() {
        #expect(LaunchEnvironment.isRunningTests(environment: [:]) == false)
        #expect(LaunchEnvironment.isRunningTests(environment: ["PATH": "/usr/bin"]) == false)
    }
}
