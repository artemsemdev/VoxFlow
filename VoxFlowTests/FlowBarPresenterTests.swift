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
