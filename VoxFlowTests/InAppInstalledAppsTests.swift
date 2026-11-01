import Foundation
import Testing
@testable import VoxFlow

@Suite("In-app rule targets")
struct InAppInstalledAppsTests {
    @Test func onlyThisAppCanBeConfigured() async {
        let own = InstalledApp(bundleID: "test.store", name: "VoxFlow")
        let provider = InAppInstalledApps(app: own)
        #expect(provider.installedApps() == [own])
        #expect(provider.name(forBundleID: own.bundleID) == "VoxFlow")
        #expect(provider.name(forBundleID: "com.apple.mail") == nil)
        #expect(await provider.pickApplication() == own.bundleID)
    }
}
