import Foundation
import Synchronization
import VoxFlowCore
@testable import VoxFlowDictation

/// Collects the feed and returns a scripted result when it ends; `cancelledCount` proves aborts propagate.
final class FakeDictationTranscriber: DictationTranscribing, Sendable {
    private struct State {
        var result = DictationResult.empty; var events: [DictationEvent] = []; var calls = 0; var cancelled = 0
        var received: [AudioChunk] = []
        var receivedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var cancelledWaiters: [CheckedContinuation<Void, Never>] = []
        /// How many `transcribe()` calls have returned (by throwing or by returning normally).
        var returned = 0
        var returnedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }
    private let state = Mutex(State())
    /// When set, `transcribe` awaits this gate after the feed ends and before returning —
    /// lets a test hold "processing" open past the feed's end (e.g. to let a timer fire first).
    private let hold: Gate?
    /// Models a transcribe call whose own cancellation check ran just before the real cancellation
    /// landed (`WindowedTranscriber`'s narrow window): it returns the scripted result normally instead
    /// of throwing `.cancelled`, so a test can prove a controller-side guard — not this fake's own
    /// cancellation check — is what keeps a torn-down capture's result out of a newer one.
    private let ignoresCancellation: Bool

    init(result: DictationResult, events: [DictationEvent] = [], hold: Gate? = nil, ignoresCancellation: Bool = false) {
        state.withLock { $0.result = result; $0.events = events }
        self.hold = hold
        self.ignoresCancellation = ignoresCancellation
    }

    var calls: Int { state.withLock { $0.calls } }
    var cancelledCount: Int { state.withLock { $0.cancelled } }
    var receivedSeconds: TimeInterval { state.withLock { $0.received.reduce(0) { $0 + $1.duration } } }

    /// Suspends until at least `count` chunks have arrived from the controller's feed — lets a test
    /// synchronize with the controller's own actor-hop before triggering the next event (no sleeps).
    func waitUntilReceived(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { s -> Bool in
                if s.received.count >= count { return true }
                s.receivedWaiters.append((count, continuation)); return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Suspends until the transcriber has recorded a cancellation — lets a test synchronize with the
    /// controller's own actor-hop before asserting on `cancelledCount` (no sleeps).
    func waitUntilCancelled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { s -> Bool in
                if s.cancelled > 0 { return true }
                s.cancelledWaiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Suspends until at least `count` `transcribe()` calls have returned (thrown or returned
    /// normally) — for a test that needs to know a specific call has actually finished, rather than
    /// hoping a bare `Task.yield()` happened to schedule far enough (M7).
    func waitForReturns(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { s -> Bool in
                if s.returned >= count { return true }
                s.returnedWaiters.append((count, continuation)); return false
            }
            if ready { continuation.resume() }
        }
    }

    private func markReturned() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.returned += 1
            let ready = s.returnedWaiters.filter { $0.count <= s.returned }
            s.returnedWaiters.removeAll { $0.count <= s.returned }
            return ready.map(\.continuation)
        }
        waiters.forEach { $0.resume() }
    }

    func transcribe(_ chunks: AsyncStream<AudioChunk>, options: TranscriptionOptions,
                    onEvent: @Sendable @escaping (DictationEvent) async -> Void) async throws -> DictationResult {
        state.withLock { $0.calls += 1 }
        for event in state.withLock({ $0.events }) { await onEvent(event) }
        for await chunk in chunks {
            let waiters: [CheckedContinuation<Void, Never>] = state.withLock { s in
                s.received.append(chunk)
                let ready = s.receivedWaiters.filter { $0.count <= s.received.count }
                s.receivedWaiters.removeAll { $0.count <= s.received.count }
                return ready.map(\.continuation)
            }
            waiters.forEach { $0.resume() }
        }
        if let hold { await hold.wait() }
        defer { markReturned() }
        if !ignoresCancellation, Task.isCancelled {
            let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.cancelled += 1
                defer { s.cancelledWaiters.removeAll() }
                return s.cancelledWaiters
            }
            waiters.forEach { $0.resume() }
            throw DictationError.cancelled
        }
        return state.withLock { $0.result }
    }
}
