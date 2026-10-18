import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowDictation

@Suite("Retry expiry scheduling", .timeLimit(.minutes(1)))
struct RetryExpirySchedulingTests {
    @Test("a delayed expiry child closes an already-expired microphone wait without sleeping")
    func delayedChildPastDeadline() async throws {
        let childStart = Gate()
        let signal = FirstSignal()
        let clock = SignallingClock(signal: signal)
        let monitor = ExpiryUseMonitor(signal: signal)
        let controller = DictationController(
            config: FlowBarConfig(), microphone: FakeMicrophone(),
            transcriber: FakeDictationTranscriber(result: DictationResult(
                text: "hello world", rawText: "hello world", segments: [], language: nil,
                duration: 1, lowConfidence: false)),
            inserter: FakeTextInserter(), clock: clock,
            preflight: {
                Preflight(excludedApp: nil, secureInput: false,
                          microphone: .inUse(by: "Zoom"), model: .loaded)
            }, loadModel: {}, options: { TranscriptionOptions() }, onSave: { _, _ in },
            copyToClipboard: { _ in }, microphoneUse: monitor,
            retryExpiryTaskFactory: { operation in
                Task { await childStart.wait(); await operation() }
            })

        await controller.fnDown()
        await monitor.subscribed.wait()
        await controller.fnUp()
        clock.advance(by: 1) // The child still has not started; its absolute deadline has passed.
        await childStart.open()

        let outcome = await signal.next()
        #expect(outcome == .monitorTerminated)
        #expect(await controller.state == .idle)
        if outcome != .monitorTerminated { await controller.anyKey() }
    }
}

private final class SignallingClock: MonotonicClock, Sendable {
    private let value = Mutex<TimeInterval>(0)
    private let backing = FakeClock()
    private let signal: FirstSignal
    init(signal: FirstSignal) { self.signal = signal }
    func now() -> TimeInterval { value.withLock { $0 } }
    func advance(by seconds: TimeInterval) { value.withLock { $0 += seconds } }
    func sleep(for seconds: TimeInterval) async throws {
        if seconds <= 0 { signal.send(.nonpositiveSleep) }
        try await backing.sleep(for: seconds)
    }
}

private final class ExpiryUseMonitor: MicrophoneUseMonitoring, Sendable {
    private let signal: FirstSignal
    let subscribed = Gate()
    init(signal: FirstSignal) { self.signal = signal }
    func currentState() -> MicrophoneUseState { .inUse(by: "Zoom") }
    func freshState() -> MicrophoneUseState { currentState() }
    func changes() -> AsyncStream<MicrophoneUseState> {
        AsyncStream { continuation in
            continuation.onTermination = { [signal] _ in signal.send(.monitorTerminated) }
            Task { await subscribed.open() }
        }
    }
}

private final class FirstSignal: Sendable {
    enum Value: Sendable, Equatable { case nonpositiveSleep, monitorTerminated }
    private struct State {
        var value: Value?
        var waiter: CheckedContinuation<Value, Never>?
    }
    private let state = Mutex(State())
    func send(_ value: Value) {
        let waiter = state.withLock { state -> CheckedContinuation<Value, Never>? in
            guard state.value == nil else { return nil }
            state.value = value
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: value)
    }
    func next() async -> Value {
        await withCheckedContinuation { continuation in
            let value = state.withLock { state -> Value? in
                if let value = state.value { return value }
                state.waiter = continuation
                return nil
            }
            if let value { continuation.resume(returning: value) }
        }
    }
}
