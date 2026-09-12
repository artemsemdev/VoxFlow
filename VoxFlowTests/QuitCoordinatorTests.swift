import Foundation
import Testing
import VoxFlowDictation
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("Quit confirmation") @MainActor
struct QuitCoordinatorTests {
    @Test("idle and paused dictation quit directly without a confirmation", arguments: [FlowBarState.idle, .paused(until: 100), .copied(.accessibilityDenied)])
    func idle(state: FlowBarState) async {
        var quits = 0
        let coordinator = QuitCoordinator(snapshot: { QuitActivity(queueRunning: false, fileName: nil, progress: nil, dictation: state) },
            present: { _ in Issue.record("unexpected prompt"); return .cancel }, finish: { Issue.record("unexpected finish"); return true }, quit: { quits += 1 })
        await coordinator.request()
        #expect(quits == 1)
        #expect(coordinator.allowsTermination)
    }

    @Test("cancel retains work, quit anyway skips finishing, finish waits before quitting", arguments: QuitCoordinator.Choice.allCases)
    func choice(choice: QuitCoordinator.Choice) async {
        var events: [String] = []
        let coordinator = QuitCoordinator(snapshot: { QuitActivity(queueRunning: true, fileName: "interview.m4a", progress: 0.72, dictation: .idle, etaText: "about 3 min left") },
            present: { activity in
                #expect(activity.title == "A file is still transcribing")
                #expect(activity.message.contains("72% done (about 3 min left)"))
                events.append("prompt"); return choice
            }, finish: { events.append("finish"); return true }, quit: { events.append("quit") })
        await coordinator.request()
        #expect(events == (choice == .cancel ? ["prompt"] : choice == .quitAnyway ? ["prompt", "quit"] : ["prompt", "finish", "quit"]))
        #expect(coordinator.allowsTermination == (choice != .cancel))
    }

    @Test("dictation recording and processing both require a confirmation")
    func activeDictation() {
        let states: [FlowBarState] = [.loadingModel(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)),
            .armed(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)), .tapped(Pending(downAt: 0, fnIsDown: false, resolvedMode: nil)),
            .listening(Listening(mode: .handsFree, startedAt: 0, language: nil)),
            .processing(Processing(startedAt: 0, takingLonger: false, limitReached: false, partialText: ""))]
        for state in states {
            #expect(QuitActivity(queueRunning: false, fileName: nil, progress: nil, dictation: state).isBusy)
        }
    }

    @Test("finish requested while recording flushes audio without marking a duration limit")
    func finishRecording() {
        var machine = FlowBarMachine()
        machine.state = .listening(Listening(mode: .handsFree, startedAt: 0, language: nil))
        let effects = machine.handle(.finishRequested, now: 2)
        #expect(effects.contains(.finishCapture))
        guard case .processing(let value) = machine.state else { Issue.record("not processing"); return }
        #expect(!value.limitReached)
    }
    @Test("repeated quit requests cannot bypass the pending finish")
    func repeatedRequest() async {
        let entered = Gate(), release = Gate()
        var quits = 0, prompts = 0
        let coordinator = QuitCoordinator(snapshot: { QuitActivity(queueRunning: true, fileName: nil, progress: nil, dictation: .idle) },
            present: { _ in prompts += 1; return .finish },
            finish: { await entered.open(); await release.wait(); return true }, quit: { quits += 1 })
        let first = Task { await coordinator.request() }
        await entered.wait()
        await coordinator.request()
        #expect(quits == 0)
        #expect(prompts == 1)
        await release.open()
        await first.value
        #expect(quits == 1)
    }

    @Test("finishing a recording waits until its history write completes")
    func waitsForHistory() async {
        let saveStarted = Gate(), saveReleased = Gate()
        let controller = DictationController(config: FlowBarConfig(), microphone: FakeMicrophone(),
            transcriber: FakeDictationTranscriber(result: DictationResult(text: "hello", rawText: "hello", segments: [], language: nil,
                                                                        duration: 2, lowConfidence: false)),
            inserter: FakeTextInserter(), clock: FakeClock(),
            preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
            loadModel: {}, options: { TranscriptionOptions() },
            onSave: { _, _ in await saveStarted.open(); await saveReleased.wait() }, copyToClipboard: { _ in })
        await controller.shortcutDown(.handsFree)
        var finished = false
        let task = Task { await controller.finishForTermination(); finished = true }
        await saveStarted.wait()
        #expect(!finished)
        #expect(await controller.hasPendingHistorySave)
        await saveReleased.open()
        await task.value
        #expect(finished)
    }

    @Test("failed export keeps the app open and restores normal operation")
    func failedFinish() async {
        #expect(QuitActivity(queueRunning: false, fileName: nil, progress: nil, dictation: .idle, hasUnsavedTranscript: true).isBusy)
        var resumed = false
        let coordinator = QuitCoordinator(snapshot: { QuitActivity(queueRunning: true, fileName: nil, progress: nil, dictation: .idle) },
            present: { _ in .finish }, finish: { false }, resume: { resumed = true }, quit: { Issue.record("must retain failed export") })
        await coordinator.request()
        #expect(resumed)
        #expect(!coordinator.allowsTermination)
    }

    @Test("termination invalidates suspended preflight and blocks new starts until cancellation")
    func freezesStarts() async {
        let entered = Gate(), release = Gate()
        let controller = DictationController(config: FlowBarConfig(), microphone: FakeMicrophone(),
            transcriber: FakeDictationTranscriber(result: .empty), inserter: FakeTextInserter(), clock: FakeClock(),
            preflight: { await entered.open(); await release.wait()
                return Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
            loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in }, copyToClipboard: { _ in })
        let activation = Task { await controller.shortcutDown(.handsFree) }
        await entered.wait()
        #expect(await controller.beginTermination())
        await release.open()
        await activation.value
        #expect(await controller.state == .idle)
        await controller.shortcutDown(.handsFree)
        #expect(await controller.state == .idle)
        await controller.cancelTermination()
        await controller.shortcutDown(.handsFree)
        #expect(await controller.state.hasUnfinishedCapture)
        await controller.finishForTermination()
    }

}
