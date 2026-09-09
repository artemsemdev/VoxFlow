import Testing
import VoxFlowDictation
@testable import VoxFlow

@Suite("MenuBarHintPolicy")
struct MenuBarHintPolicyTests {
    @Test("shouldShow: only once — true until hintShown is persisted, then never again")
    func shouldShow() {
        #expect(MenuBarHintPolicy.shouldShow(hintShown: false, showInMenuBar: true))
        #expect(!MenuBarHintPolicy.shouldShow(hintShown: true, showInMenuBar: true))
    }

    @Test("shouldShow: never when the menu bar item itself is off (M4) — even if it hasn't been shown yet")
    func shouldShowGatedOnShowInMenuBar() {
        #expect(!MenuBarHintPolicy.shouldShow(hintShown: false, showInMenuBar: false))
        #expect(!MenuBarHintPolicy.shouldShow(hintShown: true, showInMenuBar: false))
    }

    @Test("shouldDismiss: the first sign of a real dictation (armed/tapped/listening) dismisses; everything else doesn't")
    func shouldDismiss() {
        #expect(MenuBarHintPolicy.shouldDismiss(for: .armed(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil))))
        #expect(MenuBarHintPolicy.shouldDismiss(for: .tapped(Pending(downAt: 0, fnIsDown: false, resolvedMode: nil))))
        #expect(MenuBarHintPolicy.shouldDismiss(for: .listening(Listening(mode: .pushToTalk, startedAt: 0, language: nil))))

        #expect(!MenuBarHintPolicy.shouldDismiss(for: .idle))
        #expect(!MenuBarHintPolicy.shouldDismiss(for: .processing(Processing(startedAt: 0, takingLonger: false, limitReached: false, partialText: ""))))
        #expect(!MenuBarHintPolicy.shouldDismiss(for: .paused(until: 60)))
    }
}
