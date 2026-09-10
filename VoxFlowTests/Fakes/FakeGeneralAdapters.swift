import Synchronization
@testable import VoxFlow

/// Scripted `LoginItemControlling` for `GeneralViewModelTests`: `shouldThrow` makes the next
/// `setEnabled(_:)` fail (simulating a denial), `isEnabled`/`setCalls` record what actually
/// happened. A `final class` (not a `let`-only struct) so the "denied" flag and call log have
/// interior mutability without `@unchecked Sendable` — `Mutex`-boxed state, same pattern as
/// `FakePermissions`.
final class FakeLoginItem: LoginItemControlling, Sendable {
    private struct State {
        var isEnabled: Bool
        var shouldThrow: Bool
        var setCalls: [Bool] = []
    }
    private let state: Mutex<State>

    init(isEnabled: Bool = false, shouldThrow: Bool = false) {
        state = Mutex(State(isEnabled: isEnabled, shouldThrow: shouldThrow))
    }

    var isEnabled: Bool { state.withLock { $0.isEnabled } }
    var setCalls: [Bool] { state.withLock { $0.setCalls } }

    func setShouldThrow(_ value: Bool) { state.withLock { $0.shouldThrow = value } }

    func setEnabled(_ enabled: Bool) throws {
        state.withLock { $0.setCalls.append(enabled) }
        if state.withLock({ $0.shouldThrow }) { throw FakeLoginItemError.denied }
        state.withLock { $0.isEnabled = enabled }
    }
}

enum FakeLoginItemError: Error { case denied }

/// Records every `AppAppearance` applied — `GeneralViewModelTests` checks both the init-time apply
/// (the persisted choice, applied immediately) and subsequent changes. `@MainActor`: matches
/// `AppearanceApplying`'s own isolation.
@MainActor
final class FakeAppearanceApplying: AppearanceApplying {
    private(set) var applied: [AppAppearance] = []
    func apply(_ appearance: AppAppearance) { applied.append(appearance) }
}

/// Records every `FlowBarPosition` applied — same reasoning as `FakeAppearanceApplying`.
@MainActor
final class FakeFlowBarPositioning: FlowBarPositioning {
    private(set) var applied: [FlowBarPosition] = []
    func apply(_ position: FlowBarPosition) { applied.append(position) }
}

/// Records every `DictationSound` played — `GeneralSoundCoordinatorTests` checks exactly which
/// sound (if any) played for each state transition.
@MainActor
final class FakeSoundPlayer: SoundPlaying {
    private(set) var played: [DictationSound] = []
    func play(_ sound: DictationSound) { played.append(sound) }
}
