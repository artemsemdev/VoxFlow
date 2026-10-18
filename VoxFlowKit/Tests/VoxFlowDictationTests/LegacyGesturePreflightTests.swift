import Testing
import VoxFlowCore
@testable import VoxFlowDictation

@Suite("Legacy gesture preflight", .timeLimit(.minutes(1)))
struct LegacyGesturePreflightTests {
    @Test("a preflight-free fn event cannot start a new capture")
    func missingPreflightCannotStart() {
        var machine = FlowBarMachine()
        let idleEffects = machine.handle(.fnDown(nil), now: 0)
        #expect(machine.state == .idle)
        #expect(idleEffects.isEmpty)
        machine.state = .micUnavailable(.inUse(by: "Zoom"))
        let blockedEffects = machine.handle(.fnDown(nil), now: 1)
        #expect(machine.state == .micUnavailable(.inUse(by: "Zoom")))
        #expect(blockedEffects.isEmpty)
    }

    @Test("fn double-tap and hands-free stop preserve the original insertion target")
    func continuationDoesNotRefreshTarget() async {
        let h = await DictationControllerTests.Harness()
        await h.controller.fnDown()
        await h.mic.waitUntilCapturing()
        await h.controller.fnUp()
        await h.controller.fnDown()
        #expect(h.preflightCalls.items.count == 1)
        #expect(await h.controller.state == .listening(Listening(mode: .handsFree, startedAt: 0, language: nil)))
        await h.controller.fnUp()
        h.mic.emit(rms: 0.3, seconds: 1)
        await h.transcriber.waitUntilReceived(1)
        await h.controller.fnDown()
        await h.saved.waitUntilCount(1)
        #expect(h.preflightCalls.items.count == 1)
        #expect(h.inserter.insertedTexts == ["hello there world"])
    }
}
