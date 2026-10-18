import Foundation

/// Selects the inert test scene before any production services or views are constructed (#143).
enum LaunchEnvironment {
    static func isRunningTests(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["VOXFLOW_TEST_HOST"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCInjectBundleInto"] != nil
    }
}
