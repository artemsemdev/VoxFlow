import Testing
import Synchronization
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowDictation

@Suite("Re-insert last dictation", .timeLimit(.minutes(1)))
struct ReinsertionTests {
    typealias Harness = DictationControllerTests.Harness
    let previous = DictationResult(text: "last saved words", rawText: "last raw words", segments: [], language: nil, duration: 2, lowConfidence: false)

    func finish(_ h: Harness) async {
        await h.controller.shortcutDown(.pushToTalk)
        _ = await h.next()
        await h.mic.waitUntilCapturing()
        await h.controller.pushToTalkReleased()
        _ = await h.next()
        _ = await h.next()
        await h.mic.waitUntilStopped()
    }

    @Test("completed session text survives a later cancellation and is inserted without another capture or history save")
    func sessionResult() async {
        let h = await Harness()
        await finish(h)
        await h.saved.waitUntilCount(1)
        await h.controller.shortcutDown(.pushToTalk)
        _ = await h.next()
        await h.mic.waitUntilCapturing()
        await h.controller.escape()
        _ = await h.next()
        #expect(await h.controller.lastResult == nil)
        let prepared = Recorder<Int>()
        let result = await h.controller.reinsertLast(prepare: { prepared.append(1); return .ready },
                                                    lastSaved: { Issue.record("session result must not read storage"); return nil })
        #expect(result == .inserted(appName: "Mail"))
        #expect(prepared.items == [1])
        #expect(h.inserter.insertedTexts == ["hello there world", "hello there world"])
        #expect(h.mic.startCount == 2)
        #expect(h.preflightCalls.items.count == 2)
        #expect(h.saved.items.count == 1)
        #expect(await h.controller.state == .inserted(appName: "Mail", words: 3, limitReached: false))
    }

    @Test("a completed session re-inserts a Unicode snippet at its cached cursor offset")
    func sessionCursorOffset() async {
        let snippet = DictationResult(text: "Привет 👋\nArtem", rawText: "/sig", segments: [], language: nil,
                                      duration: 2, lowConfidence: false, cursorOffset: 6)
        let h = await Harness(result: snippet)
        await finish(h)
        await h.saved.waitUntilCount(1)
        #expect(await h.controller.reinsertLast(prepare: { .ready }, lastSaved: {
            Issue.record("session cache must not read history"); return nil
        }) == .inserted(appName: "Mail"))
        #expect(h.inserter.insertedTexts == [snippet.text, snippet.text])
        #expect(h.inserter.cursorOffsets == [6, 6])
    }

    @Test("a stored fallback can be reinserted on a fresh launch without microphone/model checks; clipboard fallback is retained")
    func storedResult() async {
        let h = await Harness(preflight: Preflight(excludedApp: nil, secureInput: false, microphone: .denied, model: .notInstalled(sizeBytes: 1)))
        h.inserter.setResult(.copiedToClipboard(reason: .noTextField))
        let result = await h.controller.reinsertLast(prepare: { .ready }, lastSaved: { previous })
        #expect(result == .copiedToClipboard(reason: .noTextField))
        #expect(h.inserter.insertedTexts == [previous.text])
        #expect(h.mic.startCount == 0 && h.preflightCalls.items.isEmpty && h.saved.items.isEmpty)
        #expect(await h.controller.state == .copied(.noTextField))
    }

    @Test("history fallback has no cursor metadata")
    func storedCursorOffsetIsNil() async {
        let h = await Harness()
        #expect(await h.controller.reinsertLast(prepare: { .ready }, lastSaved: { previous }) == .inserted(appName: "Mail"))
        #expect(h.inserter.cursorOffsets == [nil])
    }

    @Test("no result and ephemeral captures never request an insertion target")
    func emptyAndEphemeral() async {
        let h = await Harness(ephemeral: { true })
        #expect(await h.controller.reinsertLast(prepare: { Issue.record("no text"); return .ready }) == nil)
        await finish(h)
        #expect(await h.controller.reinsertLast(prepare: { Issue.record("ephemeral text"); return .ready }) == nil)
        #expect(h.inserter.insertedTexts.count == 1)
        #expect(h.saved.items.isEmpty)
    }

    @Test("an ephemeral completion and a later abort preserve prior session cursor metadata")
    func ephemeralAndAbortPreserveSessionCursor() async {
        let ephemeral = Mutex(false)
        let snippet = DictationResult(text: "Best,\n\nАртём", rawText: "/sig", segments: [], language: nil,
                                      duration: 2, lowConfidence: false, cursorOffset: 7)
        let h = await Harness(result: snippet, ephemeral: { ephemeral.withLock { $0 } })
        await finish(h)
        await h.saved.waitUntilCount(1)
        ephemeral.withLock { $0 = true }
        await finish(h)
        await h.controller.shortcutDown(.pushToTalk)
        _ = await h.next()
        await h.mic.waitUntilCapturing()
        await h.controller.escape()
        _ = await h.next()
        #expect(await h.controller.reinsertLast(prepare: { .ready }, lastSaved: {
            Issue.record("session cache must survive ephemeral and aborted captures"); return nil
        }) == .inserted(appName: "Mail"))
        #expect(h.inserter.cursorOffsets.last == 7)
    }

    @Test("a target changed during preparation is abandoned without insertion or a misleading HUD")
    func changedTarget() async {
        let h = await Harness()
        #expect(await h.controller.reinsertLast(prepare: { .changed }, lastSaved: { previous }) == nil)
        #expect(h.inserter.insertedTexts.isEmpty)
        #expect(await h.controller.state == .idle)
    }

    @Test("excluded targets and paused/busy dictation cannot receive reinsertion")
    func gates() async {
        let h = await Harness()
        #expect(await h.controller.reinsertLast(prepare: { .excluded("a secure field") }, lastSaved: { previous }) == nil)
        #expect(await h.controller.state == .excluded(app: "a secure field"))
        await h.controller.pause(for: 100)
        #expect(await h.controller.reinsertLast(prepare: { Issue.record("paused"); return .ready }, lastSaved: { previous }) == nil)
        await h.controller.resume()
        await h.controller.shortcutDown(.handsFree)
        #expect(await h.controller.reinsertLast(prepare: { Issue.record("busy"); return .ready }, lastSaved: { previous }) == nil)
        #expect(h.inserter.insertedTexts.isEmpty)
        await h.controller.escape()
    }

    @Test("pending preparation excludes concurrent starts and reinsertion, and cancellation prevents a delayed paste")
    func concurrentPreparation() async {
        let h = await Harness()
        let gate = Gate(), progress = Recorder<String>()
        let pending = Task { [controller = h.controller, previous] in
            let result = await controller.reinsertLast(prepare: {
                progress.append("entered")
                await gate.wait()
                return .ready
            }, lastSaved: { previous })
            progress.append("finished")
            return result
        }
        await progress.waitUntilCount(1)
        #expect(progress.items.first == "entered")
        guard progress.items.first == "entered" else { _ = await pending.value; return }
        #expect(await h.controller.reinsertLast(prepare: { Issue.record("already reinserting"); return .ready }, lastSaved: { previous }) == nil)
        await h.controller.fnDown()
        await h.controller.shortcutDown(.pushToTalk)
        #expect(h.preflightCalls.items.isEmpty && h.mic.startCount == 0)
        await h.controller.escape()
        await gate.open()
        #expect(await pending.value == nil)
        #expect(h.inserter.insertedTexts.isEmpty)
    }

    @Test("reinsertion HUD effects never save history or start capture")
    func effects() {
        for initial: FlowBarState in [.idle, .discarded] {
            var machine = FlowBarMachine()
            machine.state = initial
            #expect(machine.handle(.reinsertionFinished(text: "two words", result: .inserted(appName: "Notes")), now: 0) ==
                    [.cancelTimer(.dismiss), .startTimer(.dismiss, seconds: 1.5)])
            #expect(machine.state == .inserted(appName: "Notes", words: 2, limitReached: false))
        }
    }

    @Test("a capture already awaiting preflight owns the target and excludes reinsertion")
    func captureOwnsPreparation() async {
        let entered = Gate(), release = Gate()
        let h = await Harness(beforePreflight: { await entered.open(); await release.wait() })
        let start = Task { [controller = h.controller] in await controller.shortcutDown(.pushToTalk) }
        await entered.wait()
        #expect(await h.controller.reinsertLast(prepare: { Issue.record("capture owns target"); return .ready },
                                               lastSaved: { Issue.record("capture already starting"); return previous }) == nil)
        await release.open()
        await start.value
        #expect(await h.controller.state == .listening(Listening(mode: .pushToTalk, startedAt: 0, language: nil)))
        await h.mic.waitUntilCapturing()
        await h.controller.escape()
    }
}
