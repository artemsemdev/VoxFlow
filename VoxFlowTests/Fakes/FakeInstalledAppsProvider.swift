import Foundation
@testable import VoxFlow

/// Scripted `InstalledAppsProviding` for Snippets/Styles tests: `apps` seeds both `name(forBundleID:)`
/// and `installedApps()` (the searchable list behind the "Only in {app}" / "Add app override"
/// pickers); `pickResult` is what `pickApplication()` returns. Only `let` storage, so this is
/// `Sendable` without `@unchecked`.
struct FakeInstalledAppsProvider: InstalledAppsProviding {
    let apps: [(bundleID: String, name: String)]
    let pickResult: String?

    init(apps: [(bundleID: String, name: String)] = [], pickResult: String? = nil) {
        self.apps = apps
        self.pickResult = pickResult
    }

    func name(forBundleID bundleID: String) -> String? {
        apps.first { $0.bundleID == bundleID }?.name
    }

    @MainActor func pickApplication() async -> String? { pickResult }

    func installedApps() -> [(bundleID: String, name: String)] { apps }
}
