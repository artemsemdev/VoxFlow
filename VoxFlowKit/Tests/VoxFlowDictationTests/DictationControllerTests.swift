import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowDictation

/// An append-only, thread-safe log of `Element`s a test can synchronize on (mirrors
/// `FakeClock.waitForSleepers`) — captured behind a class reference for `@Sendable` closures,
/// since a bare `Mutex` is `@_staticExclusiveOnly` and cannot be extracted from a stored property.
final class Recorder<Element: Sendable>: Sendable {
    private struct Waiter: Sendable { let count: Int; let continuation: CheckedContinuation<Void, Never> }
    private struct State { var items: [Element] = []; var waiters: [Waiter] = [] }
    private let state = Mutex(State())

    var items: [Element] { state.withLock { $0.items } }

    func append(_ item: Element) {
        let ready = state.withLock { s -> [Waiter] in
            s.items.append(item)
            let ready = s.waiters.filter { $0.count <= s.items.count }
            s.waiters.removeAll { $0.count <= s.items.count }
            return ready
        }
        ready.forEach { $0.continuation.resume() }
    }

    /// Suspends until at least `count` items have been appended.
    func waitUntilCount(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { s -> Bool in
                if s.items.count >= count { return true }
                s.waiters.append(Waiter(count: count, continuation: continuation)); return false
            }
            if ready { continuation.resume() }
        }
    }
}

@Suite("DictationController", .timeLimit(.minutes(1)))
struct DictationControllerTests {
    final class Harness {
        let mic = FakeMicrophone()
        let inserter = FakeTextInserter()
        let clock = FakeClock()
        let saved = Recorder<(DictationResult, String?)>()
        let clipboard = Recorder<String>()
        let transcriber: FakeDictationTranscriber
        let controller: DictationController
        var states: AsyncStream<FlowBarState>.Iterator

        init(result: DictationResult = DictationResult(text: "hello there world", rawText: "hello there world", segments: [], language: nil, duration: 2, lowConfidence: false),
             preflight: Preflight = Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded)) async {
            transcriber = FakeDictationTranscriber(result: result)
            controller = DictationController(config: FlowBarConfig(), microphone: mic, transcriber: transcriber, inserter: inserter, clock: clock,
                                             preflight: { preflight }, loadModel: {}, options: { TranscriptionOptions() },
                                             onSave: { [saved] r, app in saved.append((r, app)) },
                                             copyToClipboard: { [clipboard] t in clipboard.append(t) })
            states = await controller.states().makeAsyncIterator()
        }

        func next() async -> FlowBarState? { await states.next() }
    }

    @Test("hold fn, speak, release: capture → processing → inserted → idle, history saved")
    func happyPath() async throws {
        let h = await Harness()
        await h.controller.fnDown()
        #expect(await h.next() == .armed(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)))
        await h.mic.waitUntilCapturing()
        await h.clock.waitForSleepers(1)                 // hold timer
        await h.clock.advance(by: 0.25)
        #expect(await h.next() == .listening(Listening(mode: .pushToTalk, startedAt: 0, language: nil)))
        h.mic.emit(rms: 0.3, seconds: 1)
        await h.transcriber.waitUntilReceived(1)          // let the chunk reach the transcriber before releasing fn
        await h.controller.fnUp()
        guard case .processing = await h.next() else { Issue.record("expected processing"); return }
        await h.mic.waitUntilStopped()
        #expect(await h.next() == .inserted(appName: "Mail", words: 3, limitReached: false))
        #expect(h.inserter.insertedTexts == ["hello there world"])
        await h.saved.waitUntilCount(1)                    // saveHistory runs on its own task
        #expect(h.saved.items.map(\.1) == ["Mail"])
        #expect(h.transcriber.receivedSeconds == 1)
        await h.clock.waitForSleepers(1)                 // dismiss
        await h.clock.advance(by: 1.5)
        #expect(await h.next() == .idle)
    }

    @Test("a lone tap aborts capture without transcribing")
    func loneTap() async throws {
        let h = await Harness()
        await h.controller.fnDown()
        _ = await h.next()
        await h.mic.waitUntilCapturing()
        await h.controller.fnUp()
        #expect(await h.next() == .tapped(Pending(downAt: 0, fnIsDown: false, resolvedMode: nil)))
        await h.clock.waitForSleepers(1)                 // double-tap window
        await h.clock.advance(by: 0.35)
        #expect(await h.next() == .idle)
        await h.mic.waitUntilStopped()
        await h.transcriber.waitUntilCancelled()
        #expect(h.transcriber.cancelledCount == 1)
        #expect(h.inserter.insertedTexts.isEmpty)
        #expect(h.saved.items.isEmpty)
    }

    @Test("hands-free: double tap, silence stops, clipboard fallback → copied")
    func handsFreeClipboard() async throws {
        let h = await Harness()
        h.inserter.setResult(.copiedToClipboard)
        await h.controller.fnDown(); _ = await h.next()
        await h.controller.fnUp(); _ = await h.next()
        await h.controller.fnDown()
        #expect(await h.next() == .listening(Listening(mode: .handsFree, startedAt: 0, language: nil)))
        await h.clock.waitForSleepers(2)                 // cap + silence
        await h.clock.advance(by: 3)
        guard case .processing = await h.next() else { Issue.record("expected processing"); return }
        #expect(await h.next() == .copied)
        await h.saved.waitUntilCount(1)                    // saveHistory runs on its own task
        #expect(h.saved.items.count == 1)
    }

    @Test("esc while listening discards: transcriber cancelled, nothing inserted")
    func escape() async throws {
        let h = await Harness()
        await h.controller.fnDown(); _ = await h.next()
        await h.mic.waitUntilCapturing()
        await h.clock.waitForSleepers(1); await h.clock.advance(by: 0.25)
        _ = await h.next()
        await h.controller.escape()
        #expect(await h.next() == .discarded)
        await h.mic.waitUntilStopped()
        await h.transcriber.waitUntilCancelled()
        #expect(h.transcriber.cancelledCount == 1)
        #expect(h.inserter.insertedTexts.isEmpty)
    }

    @Test("preflight failure never opens the microphone")
    func gated() async throws {
        let h = await Harness(preflight: Preflight(excludedApp: "1Password", secureInput: false, microphone: .granted, model: .loaded))
        await h.controller.fnDown()
        #expect(await h.next() == .excluded(app: "1Password"))
        #expect(h.mic.startCount == 0)
        await h.controller.anyKey()
        #expect(await h.next() == .idle)
    }

    @Test("microphone failure mid-listening → FB-07 and capture torn down")
    func micFailure() async throws {
        let h = await Harness()
        await h.controller.fnDown(); _ = await h.next()
        await h.mic.waitUntilCapturing()
        await h.clock.waitForSleepers(1); await h.clock.advance(by: 0.25)
        _ = await h.next()
        h.mic.fail(.noInputDevice)
        #expect(await h.next() == .micUnavailable(.noDevice))
        await h.transcriber.waitUntilCancelled()
        #expect(h.transcriber.cancelledCount == 1)
    }

    @Test("20 s without a result → didn't catch with raw text; copy raw uses the partial")
    func timeout() async throws {
        let slow = FakeDictationTranscriber(result: .empty, events: [.partialText("so far")], hold: Gate())
        let mic = FakeMicrophone(), clock = FakeClock(), clipboard = Recorder<String>()
        let controller = DictationController(config: FlowBarConfig(), microphone: mic, transcriber: slow, inserter: FakeTextInserter(), clock: clock,
                                             preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
                                             loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in },
                                             copyToClipboard: { t in clipboard.append(t) })
        var states = await controller.states().makeAsyncIterator()
        await controller.fnDown(); _ = await states.next()
        await mic.waitUntilCapturing()
        await clock.waitForSleepers(1); await clock.advance(by: 0.25)
        _ = await states.next()
        // Never finish the feed from the fake's side: `fnUp` finishes it, but the fake keeps the result until the stream ends —
        // so hold the stream open by making the transcriber wait: emit nothing and let the 20 s timer fire first.
        await controller.fnUp()
        _ = await states.next()                            // processing
        await clock.waitForSleepers(2)                     // takingLonger + processingTimeout
        await clock.advance(by: 20)
        var state = await states.next()
        if case .processing = state { state = await states.next() }   // takingLonger flips first at 8 s
        #expect(state == .didntCatch(rawAvailable: true))
        await controller.copyRaw()
        #expect(clipboard.items == ["so far"])
    }

    @Test("elapsed tracks time since the dictation started while listening/processing, nil otherwise")
    func elapsedTime() async throws {
        let h = await Harness()
        #expect(await h.controller.elapsed == nil)
        await h.controller.fnDown()
        _ = await h.next()
        await h.mic.waitUntilCapturing()
        await h.clock.waitForSleepers(1)
        await h.clock.advance(by: 0.25)
        _ = await h.next()                                  // listening
        #expect(await h.controller.elapsed == 0.25)
        await h.clock.advance(by: 2)
        #expect(await h.controller.elapsed == 2.25)
        await h.controller.fnUp()
        guard case .processing = await h.next() else { Issue.record("expected processing"); return }
        #expect(await h.controller.elapsed == 0)
    }

    @Test("updateConfig applies once idle: listening keeps the old silenceStop, the next run uses the new one")
    func updateConfigAppliesWhenIdle() async throws {
        let h = await Harness()
        #expect(await h.controller.config.silenceStop == 3)
        await h.controller.fnDown(); _ = await h.next()
        await h.controller.fnUp(); _ = await h.next()
        await h.controller.fnDown()
        #expect(await h.next() == .listening(Listening(mode: .handsFree, startedAt: 0, language: nil)))

        await h.controller.updateConfig(FlowBarConfig(silenceStop: 5))
        #expect(await h.controller.config.silenceStop == 3)      // still listening: the running timer keeps the old value

        await h.controller.fnDown()                              // second fn-down in hands-free stops the dictation
        guard case .processing = await h.next() else { Issue.record("expected processing"); return }
        await h.mic.waitUntilStopped()
        #expect(await h.next() == .inserted(appName: "Mail", words: 3, limitReached: false))
        await h.saved.waitUntilCount(1)
        await h.clock.waitForSleepers(1)                         // dismiss
        await h.clock.advance(by: 1.5)
        #expect(await h.next() == .idle)
        #expect(await h.controller.config.silenceStop == 5)
    }

    @Test("currentAndChanges yields the current state before any subsequent change (M3)")
    func currentAndChangesYieldsCurrentFirst() async throws {
        let h = await Harness()
        await h.controller.fnDown()
        var iterator = await h.controller.currentAndChanges().makeAsyncIterator()
        #expect(await iterator.next() == .armed(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)))
        await h.controller.fnUp()
        #expect(await iterator.next() == .tapped(Pending(downAt: 0, fnIsDown: false, resolvedMode: nil)))
    }

    @Test("a torn-down capture's late result is never inserted or saved into a newer one, even mid-processing")
    func staleCaptureIgnored() async throws {
        let hold = Gate()
        let transcriber = FakeDictationTranscriber(
            result: DictationResult(text: "stale text", rawText: "stale text", segments: [], language: nil, duration: 1, lowConfidence: false),
            hold: hold, ignoresCancellation: true)
        let mic = FakeMicrophone(), clock = FakeClock(), inserter = FakeTextInserter()
        let saved = Recorder<(DictationResult, String?)>()
        let controller = DictationController(config: FlowBarConfig(), microphone: mic, transcriber: transcriber, inserter: inserter, clock: clock,
                                             preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
                                             loadModel: {}, options: { TranscriptionOptions() },
                                             onSave: { [saved] r, app in saved.append((r, app)) },
                                             copyToClipboard: { _ in })
        var states = await controller.states().makeAsyncIterator()

        // First dictation: armed → listening → escape, while its transcribe() call is still in flight
        // (parked on `hold`, and `ignoresCancellation` so it will return normally, not throw, once freed).
        await controller.fnDown()
        #expect(await states.next() == .armed(Pending(downAt: 0, fnIsDown: true, resolvedMode: nil)))
        await mic.waitUntilCapturing()
        await clock.waitForSleepers(1); await clock.advance(by: 0.25)
        #expect(await states.next() == .listening(Listening(mode: .pushToTalk, startedAt: 0, language: nil)))
        await controller.escape()
        #expect(await states.next() == .discarded)
        await mic.waitUntilStopped()

        // Second dictation, driven all the way to `.processing` — its own transcribe() call is also
        // parked on the same `hold`, so it hasn't produced a result yet either. The clock already reads
        // 0.25 from the first dictation's hold timer, so this one's `downAt`/`startedAt` follow from there.
        await controller.fnDown()
        #expect(await states.next() == .armed(Pending(downAt: 0.25, fnIsDown: true, resolvedMode: nil)))
        await mic.waitUntilCapturing()
        await clock.waitForSleepers(1); await clock.advance(by: 0.25)
        #expect(await states.next() == .listening(Listening(mode: .pushToTalk, startedAt: 0.25, language: nil)))
        await controller.fnUp()
        guard case .processing = await states.next() else { Issue.record("expected processing"); return }

        // Release both calls at once, with the second dictation still `.processing` — the worst case:
        // the first (discarded) capture's late result is the one that must be rejected, not the machine's
        // own `.processing`-only gating (which would just as happily accept either).
        await hold.open()

        // The current dictation still completes normally...
        #expect(await states.next() == .inserted(appName: "Mail", words: 2, limitReached: false))
        // ...and exactly once: the discarded capture's late result never reached insertion or history,
        // even though it shares the same text/shape and arrived while `.processing` was live. Wait for
        // both parked `transcribe()` calls to have actually returned (not a single `Task.yield()`,
        // which doesn't guarantee the stale capture's continuation was even scheduled) before asserting —
        // otherwise the assertion could pass vacuously even with the `captureID` guard removed.
        await transcriber.waitForReturns(2)
        #expect(inserter.insertedTexts.count == 1)
        await saved.waitUntilCount(1)
        #expect(saved.items.count == 1)
    }
}
