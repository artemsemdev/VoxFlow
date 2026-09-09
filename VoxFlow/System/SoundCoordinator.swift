import Observation
import VoxFlowDictation

/// Design ST-01 "Play sounds when dictation starts and ends" (ruling 4): plays `.start` on
/// entering `.listening`, `.end` on `.inserted`/`.copied` — silently does nothing while
/// `GeneralSettings.playSounds` is off. Structured exactly like `FlowBarPresenter`'s own
/// `bind(to:)`/`trackState(of:)` pair (same `withObservationTracking` re-registration dance), so
/// the two coordinators that watch `DictationCoordinator.state` for unrelated reasons don't
/// diverge in how they do it.
@MainActor
final class SoundCoordinator {
    private let settings: GeneralSettings
    private let player: any SoundPlaying
    private var isBound = false
    private(set) var lastState: FlowBarState = .idle

    init(settings: GeneralSettings, player: any SoundPlaying) {
        self.settings = settings
        self.player = player
    }

    /// Directly exercised by `GeneralSoundCoordinatorTests` (mirrors `FlowBarPresenterTests`'
    /// `stateChanged(to:)` calls) — production wiring is `bind(to:)` below.
    func stateChanged(to state: FlowBarState) {
        defer { lastState = state }
        guard settings.playSounds else { return }
        if case .listening = state, !isListening(lastState) {
            player.play(.start)
        }
        switch state {
        case .inserted, .copied: player.play(.end)
        default: break
        }
    }

    private func isListening(_ state: FlowBarState) -> Bool {
        if case .listening = state { true } else { false }
    }

    /// Production wiring: tracks `coordinator.state` via `withObservationTracking`,
    /// re-registering after each change. Idempotent, same reasoning as `FlowBarPresenter.bind(to:)`.
    func bind(to coordinator: DictationCoordinator) {
        guard !isBound else { return }
        isBound = true
        stateChanged(to: coordinator.state)
        trackState(of: coordinator)
    }

    private func trackState(of coordinator: DictationCoordinator) {
        withObservationTracking { _ = coordinator.state } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.stateChanged(to: coordinator.state)
                self.trackState(of: coordinator)
            }
        }
    }
}
