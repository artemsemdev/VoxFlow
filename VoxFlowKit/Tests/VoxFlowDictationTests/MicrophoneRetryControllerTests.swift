import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowDictation

@Suite("Microphone retry controller", .timeLimit(.minutes(1)))
struct MicrophoneRetryControllerTests {
    @Test("hands-free retries once through fresh preflight after the holder releases")
    func retriesOnce() async throws {
        let gate = Gate()
        let h = Harness(retryGate: gate)
        await h.controller.shortcutDown(.handsFree)
        #expect(await h.controller.state == .micUnavailable(.inUse(by: "Zoom")))
        try #require(h.use.subscriberCount == 1)
        h.use.send(.available)
        await h.calls.waitUntilCount(2)
        h.use.send(.available)
        await gate.open()
        await h.mic.waitUntilCapturing()
        #expect(h.mic.startCount == 1)
        #expect(h.calls.items.count == 2)
        #expect(await h.controller.state == .listening(Listening(mode: .handsFree, startedAt: 0, language: nil)))
        await h.controller.escape()
        await h.mic.waitUntilStopped()
    }

    @Test("PTT release invalidates retry while fresh preflight is suspended")
    func releaseDuringPreflight() async throws {
        let gate = Gate()
        let h = Harness(retryGate: gate)
        await h.controller.shortcutDown(.pushToTalk)
        try #require(h.use.subscriberCount == 1)
        h.use.send(.available)
        await h.calls.waitUntilCount(2)
        await h.controller.pushToTalkReleased()
        await gate.open()
        await h.use.terminated.wait()
        #expect(h.mic.startCount == 0)
        #expect(h.inserter.insertedTexts.isEmpty)
    }

    @Test("fresh privacy checks stop retry without opening the microphone")
    func freshPrivacy() async throws {
        let blocked = Preflight(excludedApp: "Private", secureInput: false, microphone: .granted, model: .loaded)
        let h = Harness(retryChecks: blocked)
        await h.controller.shortcutDown(.handsFree)
        try #require(h.use.subscriberCount == 1)
        var states = await h.controller.states().makeAsyncIterator()
        h.use.send(.available)
        #expect(await states.next() == .excluded(app: "Private"))
        await h.use.terminated.wait()
        #expect(h.mic.startCount == 0)
        #expect(h.inserter.insertedTexts.isEmpty)
    }

    @Test("second tap during retry preflight resumes the newly resolved hands-free intent")
    func secondTapDuringPreflight() async throws {
        let gate = Gate()
        let h = Harness(retryGate: gate)
        await h.controller.fnDown()
        try #require(h.use.subscriberCount == 1)
        h.use.send(.available)
        await h.calls.waitUntilCount(2)
        await h.controller.fnUp()
        await h.controller.fnDown()
        await gate.open()
        await h.mic.waitUntilCapturing()
        #expect(h.calls.items.count == 3)
        #expect(await h.controller.state == .listening(Listening(mode: .handsFree, startedAt: 0, language: nil)))
        await h.controller.escape()
        await h.mic.waitUntilStopped()
    }

    @Test("a blocked single tap expires and removes its observation")
    func tapExpiry() async throws {
        let h = Harness()
        await h.controller.fnDown()
        try #require(h.use.subscriberCount == 1)
        await h.controller.fnUp()
        await h.clock.waitForSleepers(1)
        await h.clock.advance(by: 0.35)
        await h.use.terminated.wait()
        #expect(await h.controller.state == .idle)
        #expect(h.mic.startCount == 0)
        h.use.send(.available)
        #expect(h.use.subscriberCount == 0)
    }

    @Test("reinsertion cancels a blocked microphone retry")
    func reinsertionCancelsRetry() async throws {
        let h = Harness()
        await h.controller.shortcutDown(.handsFree)
        try #require(h.use.subscriberCount == 1)
        let saved = DictationResult(text: "saved text", rawText: "saved text", segments: [],
                                   language: nil, duration: 1, lowConfidence: false)
        let result = await h.controller.reinsertLast(prepare: { .ready }, lastSaved: { saved })
        #expect(result != nil)
        #expect(h.inserter.insertedTexts == ["saved text"])
        #expect(h.use.subscriberCount == 0)
        // Clean up the old implementation after its observable subscription failure.
        await h.controller.escape()
        await h.use.terminated.wait()
        h.use.send(.available)
        #expect(h.calls.items.count == 1)
        #expect(h.mic.startCount == 0)
    }

    @Test("a different shortcut supersedes a suspended microphone retry")
    func foreignShortcutDuringPreflight() async throws {
        let gate = Gate()
        let h = Harness(retryGate: gate)
        await h.controller.shortcutDown(.handsFree)
        try #require(h.use.subscriberCount == 1)
        h.use.send(.available)
        await h.calls.waitUntilCount(2)
        await h.controller.shortcutDown(.pushToTalk)
        await gate.open()
        await h.mic.waitUntilCapturing()
        #expect(h.calls.items.count == 3)
        #expect(h.mic.startCount == 1)
        #expect(await h.controller.state == .listening(Listening(mode: .pushToTalk, startedAt: 0, language: nil)))
        await h.controller.escape()
        await h.mic.waitUntilStopped()
    }

    @Test("a queued replacement still responds to release and cancellation", arguments: [0, 1, 2, 3])
    func cancelQueuedReplacement(_ action: Int) async throws {
        let gate = Gate()
        let h = Harness(retryGate: gate)
        await h.controller.shortcutDown(.handsFree)
        try #require(h.use.subscriberCount == 1)
        h.use.send(.available)
        await h.calls.waitUntilCount(2)
        await h.controller.shortcutDown(.pushToTalk)
        switch action {
        case 0: await h.controller.pushToTalkReleased()
        case 1: await h.controller.escape()
        case 2: await h.controller.anyKey()
        default: await h.controller.pause(for: 60)
        }
        await gate.open()
        await h.use.terminated.wait()
        #expect(h.calls.items.count == 2)
        #expect(h.mic.startCount == 0)
    }

    private final class Harness {
        let mic = FakeMicrophone()
        let use = FakeUseMonitor()
        let inserter = FakeTextInserter()
        let clock = FakeClock()
        let calls = Recorder<Int>()
        let controller: DictationController

        init(retryGate: Gate? = nil, retryChecks: Preflight? = nil) {
            controller = DictationController(
                config: FlowBarConfig(), microphone: mic,
                transcriber: FakeDictationTranscriber(result: DictationResult(text: "hello world", rawText: "hello world",
                    segments: [], language: nil, duration: 1, lowConfidence: false)),
                inserter: inserter, clock: clock,
                preflight: { [calls, use] in
                    let count = calls.items.count + 1
                    calls.append(count)
                    if count > 1 {
                        await retryGate?.wait()
                        if let retryChecks { return retryChecks }
                    }
                    let microphone: MicrophoneAccess
                    if case .inUse(let name) = use.currentState() { microphone = .inUse(by: name) }
                    else { microphone = .granted }
                    return Preflight(excludedApp: nil, secureInput: false, microphone: microphone, model: .loaded)
                }, loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in },
                copyToClipboard: { _ in }, microphoneUse: use)
        }
    }
}

private final class FakeUseMonitor: MicrophoneUseMonitoring, Sendable {
    private struct State {
        var value = MicrophoneUseState.inUse(by: "Zoom")
        var continuations: [UUID: AsyncStream<MicrophoneUseState>.Continuation] = [:]
    }
    private let state = Mutex(State())
    let terminated = Gate()
    var subscriberCount: Int { state.withLock { $0.continuations.count } }
    func currentState() -> MicrophoneUseState { state.withLock { $0.value } }
    func freshState() -> MicrophoneUseState { currentState() }
    func changes() -> AsyncStream<MicrophoneUseState> {
        AsyncStream { continuation in
            let id = UUID()
            state.withLock { $0.continuations[id] = continuation }
            continuation.onTermination = { [self] _ in
                state.withLock { $0.continuations[id] = nil }
                Task { await terminated.open() }
            }
        }
    }
    func send(_ value: MicrophoneUseState) {
        let continuations = state.withLock { state in
            state.value = value
            return Array(state.continuations.values)
        }
        continuations.forEach { $0.yield(value) }
    }
}
