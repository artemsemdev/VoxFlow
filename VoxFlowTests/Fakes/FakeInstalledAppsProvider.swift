import Foundation
import Synchronization
@testable import VoxFlow

/// Scripted `InstalledAppsProviding` for Snippets/Styles tests: `apps` seeds both `name(forBundleID:)`
/// and `installedApps()` (the searchable list behind the "Only in {app}" / "Add app override"
/// pickers); `pickResult` is what `pickApplication()` returns. `scanCount` counts calls to
/// `installedApps()` — used to assert the view models cache the scan per sheet presentation rather
/// than re-running it on every re-render/keystroke (review B1). A `final class` (not the earlier
/// `let`-only struct) so the counter can have interior mutability without `@unchecked Sendable` — a
/// single `Mutex`-boxed `Int`, same pattern as `SnapshotBox`/`FakeContacts` elsewhere in the suite.
final class FakeInstalledAppsProvider: InstalledAppsProviding, Sendable {
    private let items: [InstalledApp]
    private let pickResult: String?
    private let scanCountBox: Mutex<Int>

    init(apps: [InstalledApp] = [], pickResult: String? = nil) {
        items = apps
        self.pickResult = pickResult
        scanCountBox = Mutex(0)
    }

    /// Convenience for the common case (most tests don't care about icons/hosting-app hints) — a
    /// bare `(bundleID, name)` pair per app.
    convenience init(apps: [(bundleID: String, name: String)], pickResult: String? = nil) {
        self.init(apps: apps.map { InstalledApp(bundleID: $0.bundleID, name: $0.name) }, pickResult: pickResult)
    }

    var scanCount: Int { scanCountBox.withLock { $0 } }

    func name(forBundleID bundleID: String) -> String? {
        items.first { $0.bundleID == bundleID }?.name
    }

    @MainActor func pickApplication() async -> String? { pickResult }

    func installedApps() -> [InstalledApp] {
        scanCountBox.withLock { $0 += 1 }
        return items
    }
}
