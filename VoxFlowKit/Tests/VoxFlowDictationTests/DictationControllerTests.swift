import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowDictation

/// An append-only, thread-safe log of `Element`s a test can synchronize on (mirrors
/// `FakeClock.waitForSleepers`) — captured behind a class reference for `@Sendable` closures,
/// since a bare `Mutex` is `@_staticExclusiveOnly` and cannot be extracted from a stored property.
final class Recorder<Element: Sendable>: @unchecked Sendable {
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

@Suite("DictationController")
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
        let mic = FakeMicrophone(), clock = FakeClock(), clipboard = Mutex<[String]>([])
        let controller = DictationController(config: FlowBarConfig(), microphone: mic, transcriber: slow, inserter: FakeTextInserter(), clock: clock,
                                             preflight: { Preflight(excludedApp: nil, secureInput: false, microphone: .granted, model: .loaded) },
                                             loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in },
                                             copyToClipboard: { t in clipboard.withLock { $0.append(t) } })
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
        #expect(clipboard.withLock { $0 } == ["so far"])
    }
}
