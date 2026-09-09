import Foundation
import VoxFlowCore

/// The five onboarding screens (design ONB-01…05); ONB-02a (Accessibility denied) is a branch of
/// `.permissions`, not its own case — see `OnboardingViewModel.showsAccessibilityDenied`.
enum OnboardingStep: Int, CaseIterable, Sendable, Equatable {
    case welcome, permissions, hotkey, model, tryIt
}

/// Onboarding's persisted progress: which step to resume at (a relaunch mid-flow reopens where it
/// left off), whether the flow ever finished (gates `AppDelegate`'s first-launch routing), and
/// whether the user chose the clipboard fallback after Accessibility was denied (ONB-02a) — read
/// again wherever dictation decides whether it can type directly or only copy to the clipboard.
@Observable @MainActor
final class OnboardingState {
    enum Keys {
        static let step = "onboarding.step"
        static let completed = "onboarding.completed"
        static let clipboardFallback = "onboarding.clipboardFallback"
    }

    private let store: any KeyValueStore

    var step: OnboardingStep { didSet { store.set(String(step.rawValue), forKey: Keys.step) } }
    var completed: Bool { didSet { store.set(completed ? "1" : "0", forKey: Keys.completed) } }
    var accessibilitySkipped: Bool { didSet { store.set(accessibilitySkipped ? "1" : "0", forKey: Keys.clipboardFallback) } }

    init(store: any KeyValueStore) {
        self.store = store
        step = store.string(forKey: Keys.step).flatMap { Int($0) }.flatMap(OnboardingStep.init(rawValue:)) ?? .welcome
        completed = store.string(forKey: Keys.completed) == "1"
        accessibilitySkipped = store.string(forKey: Keys.clipboardFallback) == "1"
    }
}
