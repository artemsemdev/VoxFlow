import Foundation
import VoxFlowDictation

/// What `FlowBarPresenter` shows/hides — `FlowBarPanel` in production, a fake in tests.
@MainActor
protocol FlowBarPanelling: AnyObject {
    var isVisible: Bool { get }
    func show()
    func hide()
}

/// The delayed "hide after idle" — a real `Task.sleep` in production (`TaskHideScheduler`), a
/// hand-fired closure in tests (`FakeScheduler`) so nothing in the test suite sleeps.
@MainActor
protocol HideScheduling: AnyObject {
    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void)
    func cancel()
}

/// Production `HideScheduling`: a cancellable `Task` holding `Task.sleep`. UI timing only — never
/// exercised by a test (`FakeScheduler` stands in there).
@MainActor
final class TaskHideScheduler: HideScheduling {
    private var task: Task<Void, Never>?

    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            block()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Drives `FlowBarPanelling` off `DictationCoordinator.state` (via `bind(to:)`) or directly
/// (`stateChanged(to:)`, what `FlowBarPresenterTests` exercises): show immediately on any non-idle
/// state, hide `idleHideDelay` seconds after the state returns to idle — cancelling that pending
/// hide the moment activity resumes.
@MainActor
final class FlowBarPresenter {
    private let panel: any FlowBarPanelling
    private let scheduler: any HideScheduling
    private let idleHideDelay: TimeInterval
    /// FB-09: unlike every other non-idle state, `.paused` sticks around for up to an hour — the
    /// pill itself must not, so it auto-hides `pausedHideDelay` seconds after entering `.paused`
    /// instead of waiting for a return to `.idle` (which may not happen for a long time).
    private let pausedHideDelay: TimeInterval
    private var hasPendingHide = false
    private var isBound = false
    /// The previous call's state — lets `.paused → .idle` (a resume) be told apart from any other
    /// arrival at `.idle`, so resuming briefly re-shows the pill as a confirmation even if it had
    /// already auto-hidden while paused.
    private var previousState: FlowBarState = .idle

    init(panel: any FlowBarPanelling, scheduler: any HideScheduling, idleHideDelay: TimeInterval = 6, pausedHideDelay: TimeInterval = 3) {
        self.panel = panel
        self.scheduler = scheduler
        self.idleHideDelay = idleHideDelay
        self.pausedHideDelay = pausedHideDelay
    }

    func stateChanged(to state: FlowBarState) {
        defer { previousState = state }

        if case .paused = state {
            // Shows immediately (same as any non-idle state) then hides itself again shortly after —
            // re-entering `.paused` (a fresh `pause(for:)` after a resume) goes through this same
            // branch and shows it again.
            if hasPendingHide { scheduler.cancel() }
            panel.show()
            hasPendingHide = true
            scheduler.schedule(after: pausedHideDelay) { [weak self] in
                guard let self else { return }
                self.hasPendingHide = false
                self.panel.hide()
            }
            return
        }

        let resumedFromPause: Bool = if case .paused = previousState { true } else { false }

        guard state == .idle else {
            if hasPendingHide {
                scheduler.cancel()
                hasPendingHide = false
            }
            if !panel.isVisible { panel.show() }
            return
        }
        // Resuming (`.paused → .idle`) re-shows the pill as a brief confirmation if `pausedHideDelay`
        // already hid it — same as any other "something just happened" transition, just arriving at
        // `.idle` instead of a busy state.
        if resumedFromPause, !panel.isVisible {
            panel.show()
        }
        // M-10: says what is meant — a never-shown panel (e.g. the `.idle` state at launch) has
        // nothing to hide, so don't schedule a hide for it.
        guard panel.isVisible else { return }
        hasPendingHide = true
        scheduler.schedule(after: idleHideDelay) { [weak self] in
            guard let self else { return }
            self.hasPendingHide = false
            self.panel.hide()
        }
    }

    /// Production wiring: tracks `coordinator.state` via `withObservationTracking`, re-registering
    /// after each change (the tracking closure fires once per generation). Idempotent — a second
    /// call is a no-op rather than starting a second self-perpetuating tracking chain, which would
    /// otherwise handle every subsequent change twice.
    func bind(to coordinator: DictationCoordinator) {
        guard !isBound else { return }
        isBound = true
        stateChanged(to: coordinator.state)
        trackState(of: coordinator)
    }

    /// `withObservationTracking`'s `onChange` fires *before* the mutation that triggered it is
    /// necessarily fully settled, and re-registration happens one `Task` hop later — a second change
    /// landing in that narrow window is coalesced with the first rather than handled separately.
    /// Harmless for show/hide today (`stateChanged` always ends up looking at `coordinator.state` as
    /// of whenever it actually runs, so the presenter's terminal show/hide decision is still correct
    /// for whatever the state is by then), but worth calling out for anyone reusing this pattern
    /// somewhere the intermediate state matters.
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

/// Forwards Settings › General's "Flow Bar position" straight to `panel` when it's a real
/// `FlowBarPanel` (always true in production; test fakes conforming only to `FlowBarPanelling`
/// simply ignore it) — lets `SettingsServices` hand `GeneralViewModel` the one `FlowBarPresenter`
/// `AppServices` already exposes instead of needing the panel itself exposed too.
extension FlowBarPresenter: FlowBarPositioning {
    func apply(_ position: FlowBarPosition) {
        (panel as? FlowBarPositioning)?.apply(position)
    }
}
