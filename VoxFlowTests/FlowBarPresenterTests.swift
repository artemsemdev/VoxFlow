import Foundation
import Testing
import VoxFlowDictation
@testable import VoxFlow

@Suite("FlowBarPresenter")
@MainActor
struct FlowBarPresenterTests {
    final class FakePanel: FlowBarPanelling {
        var isVisible = false; var shows = 0; var hides = 0
        func show() { isVisible = true; shows += 1 }
        func hide() { isVisible = false; hides += 1 }
    }
    final class FakeScheduler: HideScheduling {
        var pending: (() -> Void)?; var cancelled = 0
        func schedule(after: TimeInterval, _ block: @escaping () -> Void) { pending = block }
        func cancel() { pending = nil; cancelled += 1 }
        func fire() { pending?(); pending = nil }
    }

    @Test("shows on first non-idle state, hides 6 s after idle, cancels the hide when activity resumes")
    func lifecycle() {
        let panel = FakePanel(), scheduler = FakeScheduler()
        let presenter = FlowBarPresenter(panel: panel, scheduler: scheduler, idleHideDelay: 6)
        presenter.stateChanged(to: .armed(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)))
        #expect(panel.shows == 1 && panel.isVisible)
        presenter.stateChanged(to: .listening(Listening(mode: .pushToTalk, startedAt: 0, language: nil)))
        #expect(panel.shows == 1)
        presenter.stateChanged(to: .idle)
        #expect(panel.isVisible && scheduler.pending != nil)
        presenter.stateChanged(to: .armed(Pending(downAt: 7, fnIsDown: true, resolvedMode: nil)))
        #expect(scheduler.cancelled == 1 && scheduler.pending == nil && panel.shows == 1)
        presenter.stateChanged(to: .idle)
        scheduler.fire()
        #expect(!panel.isVisible && panel.hides == 1)
    }

    @Test("M-10: idle at launch (panel never shown) schedules no hide")
    func idleAtLaunchSchedulesNoHide() {
        let panel = FakePanel(), scheduler = FakeScheduler()
        let presenter = FlowBarPresenter(panel: panel, scheduler: scheduler, idleHideDelay: 6)
        presenter.stateChanged(to: .idle)
        #expect(scheduler.pending == nil)
        #expect(panel.shows == 0 && panel.hides == 0)
    }

    @Test("FB-09: .paused shows immediately, then auto-hides pausedHideDelay seconds later — independent of idleHideDelay")
    func pausedAutoHides() {
        let panel = FakePanel(), scheduler = FakeScheduler()
        let presenter = FlowBarPresenter(panel: panel, scheduler: scheduler, idleHideDelay: 6, pausedHideDelay: 3)
        presenter.stateChanged(to: .paused(until: 3600))
        #expect(panel.shows == 1 && panel.isVisible)
        scheduler.fire()
        #expect(!panel.isVisible && panel.hides == 1)
    }

    @Test("FB-09: re-entering .paused (a fresh pause after resume) shows the pill again")
    func pausedReentryShowsAgain() {
        let panel = FakePanel(), scheduler = FakeScheduler()
        let presenter = FlowBarPresenter(panel: panel, scheduler: scheduler, idleHideDelay: 6, pausedHideDelay: 3)
        presenter.stateChanged(to: .paused(until: 3600))
        scheduler.fire()
        #expect(!panel.isVisible && panel.shows == 1)

        presenter.stateChanged(to: .idle)          // resume
        presenter.stateChanged(to: .paused(until: 7200))   // paused again
        #expect(panel.isVisible && panel.shows == 3)   // resume's confirmation show + the re-pause show
    }

    @Test("FB-09: resuming (.paused → .idle) while still visible cancels the paused-hide and schedules the normal idle hide instead")
    func resumeWhileStillVisibleUsesIdleDelay() {
        let panel = FakePanel(), scheduler = FakeScheduler()
        let presenter = FlowBarPresenter(panel: panel, scheduler: scheduler, idleHideDelay: 6, pausedHideDelay: 3)
        presenter.stateChanged(to: .paused(until: 3600))
        #expect(panel.isVisible)

        presenter.stateChanged(to: .idle)   // resumed before the 3 s paused-hide fired
        #expect(panel.isVisible && scheduler.pending != nil)
        scheduler.fire()
        #expect(!panel.isVisible && panel.hides == 1)
    }

    @Test("FB-09: resuming after the pill already auto-hid briefly re-shows it as a confirmation, then hides again after idleHideDelay")
    func resumeAfterAutoHideReshows() {
        let panel = FakePanel(), scheduler = FakeScheduler()
        let presenter = FlowBarPresenter(panel: panel, scheduler: scheduler, idleHideDelay: 6, pausedHideDelay: 3)
        presenter.stateChanged(to: .paused(until: 3600))
        scheduler.fire()   // auto-hidden already
        #expect(!panel.isVisible)

        presenter.stateChanged(to: .idle)   // resume, arriving after the auto-hide
        #expect(panel.isVisible && panel.shows == 2)
        scheduler.fire()
        #expect(!panel.isVisible)
    }

    @Test("FlowBarPanel.show() cancels an in-flight hide (C1): show(), hide(), show() leaves it fully visible")
    func panelCancellableHide() {
        let content = FlowBarContent.make(state: .idle, elapsed: 0, mode: .pushToTalk)
        let panel = FlowBarPanel(rootView: FlowBarView(content: content, levels: Array(repeating: 0, count: 14)))
        panel.show()
        panel.hide()
        panel.show()
        #expect(panel.isVisible)
        #expect(panel.alphaValue == 1)
    }
}
