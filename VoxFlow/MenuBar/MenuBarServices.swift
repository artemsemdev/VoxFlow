import Foundation

/// Thin forwarder to `AppServices.shared` (design MB-00…02) plus MB-00's hint-panel machinery,
/// which stays here rather than moving into `AppServices` — it's `NSPanel`-backed UI state
/// (`hintPanel`) tied to the menu bar scene, not one of the plain service/view-model instances the
/// controller task folded in. Used to build its own `MenuBarViewModel` (a separate composition root
/// from `AppServices`, for the same reason `SettingsServices` used to); `viewModel` now just reads
/// the one instance `AppServices` builds, so `MenuBarContent`'s existing `MenuBarServices.shared.viewModel`
/// call site keeps compiling unchanged.
@MainActor
final class MenuBarServices {
    static let shared = MenuBarServices()

    var viewModel: MenuBarViewModel { AppServices.shared.menuBarViewModel }

    /// Non-nil exactly while MB-00's hint panel is on screen — `nil` once dismissed (by "Got it",
    /// the 10 s timer, or the first `.armed`/`.listening`), which also makes `dismissHint()` and a
    /// second `showHintIfNeeded()` call both safely idempotent.
    private var hintPanel: MenuBarHintPanel?

    private init() {}

    /// MB-00: shown once, right after onboarding finishes (`OnboardingViewModel.onFinished`, wired
    /// to this from `OnboardingWindow.onAppear`) — no-ops if it's already been shown.
    func showHintIfNeeded() {
        guard hintPanel == nil, MenuBarHintPolicy.shouldShow(hintShown: AppServices.shared.onboardingState.hintShown,
                                                              showInMenuBar: AppServices.shared.generalSettings.showInMenuBar) else { return }
        let panel = MenuBarHintPanel(onGotIt: { [weak self] in self?.dismissHint() })
        hintPanel = panel
        panel.show()
        observeFirstDictation()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.dismissHint()
        }
    }

    /// Auto-dismiss on the first sign of an actual dictation (design page 4: "auto-dismiss 10 s or
    /// on first dictation") — re-registers itself after every state change until the hint is gone.
    private func observeFirstDictation() {
        withObservationTracking {
            _ = AppServices.shared.dictation.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.hintPanel != nil else { return }
                if MenuBarHintPolicy.shouldDismiss(for: AppServices.shared.dictation.state) {
                    self.dismissHint()
                } else {
                    self.observeFirstDictation()
                }
            }
        }
    }

    private func dismissHint() {
        guard hintPanel != nil else { return }
        hintPanel?.hide()
        hintPanel = nil
        AppServices.shared.onboardingState.hintShown = true
    }
}
