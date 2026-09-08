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
    private var hasPendingHide = false

    init(panel: any FlowBarPanelling, scheduler: any HideScheduling, idleHideDelay: TimeInterval = 6) {
        self.panel = panel
        self.scheduler = scheduler
        self.idleHideDelay = idleHideDelay
    }

    func stateChanged(to state: FlowBarState) {
        guard state == .idle else {
            if hasPendingHide {
                scheduler.cancel()
                hasPendingHide = false
            }
            if !panel.isVisible { panel.show() }
            return
        }
        hasPendingHide = true
        scheduler.schedule(after: idleHideDelay) { [weak self] in
            guard let self else { return }
            self.hasPendingHide = false
            self.panel.hide()
        }
    }

    /// Production wiring: tracks `coordinator.state` via `withObservationTracking`, re-registering
    /// after each change (the tracking closure fires once per generation).
    func bind(to coordinator: DictationCoordinator) {
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
