import Foundation
import VoxFlowDictation

/// Answers "may we listen right now?" from AppKit facts (design FB-07, FB-08, FB-10, 3e "Secure input").
struct PreflightBuilder: Sendable {
    let frontmost: any FrontmostAppProviding
    let permissions: any PermissionChecking
    let readiness: @Sendable () async -> ModelReadiness
    let settings: DictationSettingsSnapshot
    /// Called last, only when no gate applies — the inserter remembers the focused element (ruling 2).
    /// Takes the already-read `FrontmostApp` (I-5: the inserter must not re-read `NSWorkspace` itself,
    /// which can disagree with the app that passed the exclusion check above if the frontmost app
    /// changed in between) and is `async`+`await`ed here so the capture is structurally guaranteed to
    /// finish before `preflight()` returns, rather than being a fire-and-forget hop that happens to
    /// win a race today.
    let captureFocus: @Sendable (FrontmostApp) async -> Void

    func preflight() async -> Preflight {
        let app = frontmost.frontmostApp()
        if let id = app.bundleID, settings.excludedBundleIDs.contains(id) {
            return Preflight(excludedApp: app.name ?? id, secureInput: false, microphone: .granted, model: .loaded)
        }
        if frontmost.secureInputEnabled() {
            return Preflight(excludedApp: nil, secureInput: true, microphone: .granted, model: .loaded)
        }
        var mic = permissions.microphone()
        if mic == .notDetermined { mic = await permissions.requestMicrophone() }
        guard mic == .granted else {
            return Preflight(excludedApp: nil, secureInput: false, microphone: .denied, model: .loaded)
        }
        let model = await readiness()
        if case .notInstalled = model {
            return Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: model)
        }
        await captureFocus(app)
        return Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: model)
    }
}
