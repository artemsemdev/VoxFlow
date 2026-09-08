import Testing
import VoxFlowCore
import VoxFlowDictation
@testable import VoxFlow

@Suite("MenuBarStatus")
struct MenuBarStatusTests {
    @Test("status line follows dictation state")
    func text() {
        #expect(MenuBarStatus.text(for: .idle) == "Ready · on-device")
        let listening = FlowBarState.listening(Listening(mode: .pushToTalk, startedAt: 0, language: nil))
        #expect(MenuBarStatus.text(for: listening) == "Listening…")
        let processing = FlowBarState.processing(Processing(startedAt: 0, takingLonger: false, limitReached: false, partialText: ""))
        #expect(MenuBarStatus.text(for: processing) == "Cleaning up…")
        let inserted = FlowBarState.inserted(appName: "Mail", words: 3, limitReached: false)
        #expect(MenuBarStatus.text(for: inserted) == "Ready · on-device")
    }

    @Test("hotkey line follows the hotkey mode")
    func hotkeyLine() {
        #expect(MenuBarStatus.hotkeyLine(for: .pushToTalk) == "Hotkey: Hold fn")
        #expect(MenuBarStatus.hotkeyLine(for: .handsFree) == "Hotkey: Double-tap fn")
    }
}
