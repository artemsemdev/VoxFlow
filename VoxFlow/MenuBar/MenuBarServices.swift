import Foundation
import VoxFlowModels

/// Composition root for the menu bar (design MB-00…02) — a separate singleton from `AppServices`
/// for now (same reasoning as `SettingsServices`: another task in this plan is editing
/// `AppServices.swift`; a later controller task folds this in). Built lazily over
/// `AppServices.shared`'s own dependencies, mirroring `SettingsServices`.
@MainActor
final class MenuBarServices {
    static let shared = MenuBarServices()

    /// `modelsOnDisk` for `viewModel`, below — a standalone, explicitly-typed `@Sendable` function
    /// (not an inline closure literal in the initializer call) so the type checker resolves its
    /// isolation on its own instead of alongside the whole `MenuBarViewModel(...)` call, which left
    /// it ambiguous ("default argument cannot be both main actor-isolated and actor-isolated" /
    /// spurious "no 'async' operations" on the `installedModels` calls below).
    nonisolated private static func countModelsOnDisk() async -> Int {
        let modelStore = await AppServices.shared.modelStore
        let speech = await modelStore.installedModels(role: .speech).count
        let style = await modelStore.installedModels(role: .style).count
        return speech + style
    }

    lazy var viewModel = MenuBarViewModel(
        dictation: AppServices.shared.dictation,
        settings: AppServices.shared.dictationSettings,
        stats: AppServices.shared.statsService,
        models: AppServices.shared.modelsViewModel,
        modelsOnDisk: Self.countModelsOnDisk,
        navigation: AppServices.shared.navigation,
        now: Date.init
    )

    /// Non-nil exactly while MB-00's hint panel is on screen — `nil` once dismissed (by "Got it",
    /// the 10 s timer, or the first `.armed`/`.listening`), which also makes `dismissHint()` and a
    /// second `showHintIfNeeded()` call both safely idempotent.
    private var hintPanel: MenuBarHintPanel?

    private init() {}

    /// MB-00: shown once, right after onboarding finishes (`OnboardingViewModel.finish()`'s
    /// `onFinished` hook, wired up wherever this task's plan folds `MenuBarServices` into
    /// `AppServices`) — no-ops if it's already been shown.
    func showHintIfNeeded() {
        guard hintPanel == nil, MenuBarHintPolicy.shouldShow(hintShown: AppServices.shared.onboardingState.hintShown) else { return }
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
