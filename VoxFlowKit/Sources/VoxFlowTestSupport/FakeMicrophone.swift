import Foundation
import Synchronization
import VoxFlowCore

/// Scripted microphone: tests push chunks with `emit`, fail it with `fail`, and see when capture starts/stops.
public final class FakeMicrophone: MicrophoneCapturing, Sendable {
    private struct State: Sendable {
        var continuation: AsyncThrowingStream<MicrophoneEvent, Error>.Continuation?
        var startCount = 0
        var stopCount = 0
        var startWaiters: [CheckedContinuation<Void, Never>] = []
        var stopWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    public init() {}

    public var startCount: Int { state.withLock { $0.startCount } }
    public var stopCount: Int { state.withLock { $0.stopCount } }
    public var isCapturing: Bool { state.withLock { $0.continuation != nil } }

    public func start() -> AsyncThrowingStream<MicrophoneEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [self] _ in
                let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                    s.continuation = nil; s.stopCount += 1
                    defer { s.stopWaiters.removeAll() }
                    return s.stopWaiters
                }
                waiters.forEach { $0.resume() }
            }
            let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.continuation = continuation; s.startCount += 1
                defer { s.startWaiters.removeAll() }
                return s.startWaiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    public func emit(_ chunk: AudioChunk) {
        // Same hardening as `fail`: extract the continuation under the lock and call it outside, so a
        // future `emit` that can trigger `onTermination` (or any producer-side callback) can't re-enter
        // the (non-reentrant) `Mutex` on this thread.
        let continuation = state.withLock { $0.continuation }
        _ = continuation?.yield(.chunk(chunk))
    }
    public func emit(rms: Float, seconds: Double = 0.1) {
        let count = Int(seconds * AudioSamples.sampleRate)
        emit(AudioChunk(samples: Array(repeating: rms, count: count)))
    }
    public func fail(_ error: MicrophoneError) {
        // `finish(throwing:)` synchronously invokes `onTermination`, which itself takes `state`'s
        // lock — so the continuation must be extracted and finished *outside* `withLock`, or the
        // (non-reentrant) `Mutex` deadlocks on this thread.
        let continuation = state.withLock { $0.continuation }
        continuation?.finish(throwing: error)
    }

    public func waitUntilCapturing() async {
        await withCheckedContinuation { c in
            let ready = state.withLock { s -> Bool in
                if s.continuation != nil { return true }
                s.startWaiters.append(c); return false
            }
            if ready { c.resume() }
        }
    }

    public func waitUntilStopped() async {
        await withCheckedContinuation { c in
            let ready = state.withLock { s -> Bool in
                if s.continuation == nil && s.startCount > 0 { return true }
                s.stopWaiters.append(c); return false
            }
            if ready { c.resume() }
        }
    }
}
