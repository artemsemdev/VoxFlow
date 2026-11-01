import Foundation

/// Rules in the sandbox edition apply only to its own editor. Do not offer other apps that
/// dictation cannot reach, or scan their bundles just to populate an unusable rule picker.
struct InAppInstalledApps: InstalledAppsProviding {
    let app: InstalledApp

    init(app: InstalledApp = InstalledApp(bundleID: Bundle.main.bundleIdentifier ?? "dev.artemsem.voxflow.store",
                                          name: "VoxFlow", url: Bundle.main.bundleURL)) {
        self.app = app
    }

    func installedApps() -> [InstalledApp] { [app] }
    func name(forBundleID bundleID: String) -> String? { bundleID == app.bundleID ? app.name : nil }
    @MainActor func pickApplication() async -> String? { app.bundleID }
}
