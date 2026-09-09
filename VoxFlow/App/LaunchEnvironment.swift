import Foundation

/// Detects the XCTest host process so `AppDelegate` can skip anything that would open the mic,
/// install global monitors or touch the Keychain when the app is launched to run tests (#143).
enum LaunchEnvironment {
    static func isRunningTests(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
