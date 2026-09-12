import Foundation
import VoxFlowCore
import VoxFlowDictation

/// Answers "may we listen right now?" from AppKit facts (design FB-07, FB-08, FB-10, 3e "Secure input").
struct PreflightBuilder: Sendable {
    let frontmost: any FrontmostAppProviding
    let permissions: any PermissionChecking
    let readiness: @Sendable () async -> ModelReadiness
    let settings: DictationSettingsSnapshot
    var microphoneUse: any MicrophoneUseMonitoring = UnmonitoredMicrophoneUse()
    /// Called last, only when no gate applies — the inserter remembers the focused element (ruling 2).
    /// Takes the already-read `FrontmostApp` (I-5: the inserter must not re-read `NSWorkspace` itself,
    /// which can disagree with the app that passed the exclusion check above if the frontmost app
    /// changed in between) and is `async`+`await`ed here so the capture is structurally guaranteed to
    /// finish before `preflight()` returns, rather than being a fire-and-forget hop that happens to
    /// win a race today.
    let captureFocus: @Sendable (FrontmostApp) async -> Void
    /// Fired only on the clean path (no exclusion/secure-input/permission/model gate applies), right
    /// after `captureFocus` — lets `StyledTranscriber` read the fn-down frontmost app later (from its
    /// `FrontmostBox`) without re-querying `NSWorkspace` itself, which could disagree with the app
    /// that passed the checks above if the frontmost app changed mid-capture. Defaulted to a no-op so
    /// every existing `PreflightBuilder(...)` call site keeps compiling unchanged. `var`, not `let`:
    /// the synthesized memberwise init only turns a defaulted stored property into an overridable
    /// parameter when it's a `var` — a defaulted `let` is baked in and can't be passed at all.
    var onFrontmostCaptured: @Sendable (FrontmostApp) -> Void = { _ in }

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
        if case .inUse(let app) = microphoneUse.freshState() {
            return Preflight(excludedApp: nil, secureInput: false, microphone: .inUse(by: app), model: .loaded)
        }
        let model = await readiness()
        if case .notInstalled = model {
            return Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: model)
        }
        await captureFocus(app)
        onFrontmostCaptured(app)
        return Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: model)
    }
}
