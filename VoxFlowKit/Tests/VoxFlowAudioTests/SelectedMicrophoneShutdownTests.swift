import Foundation
import Synchronization
import Testing
import VoxFlowCore
@testable import VoxFlowAudio

@Suite("Selected microphone shutdown", .timeLimit(.minutes(1)))
struct SelectedMicrophoneShutdownTests {
    @Test("three captures release ownership and drain pending native callbacks before restarting")
    func repeatedCapture() async throws {
        let lease = MicrophoneCaptureLease()
        for _ in 0..<3 {
            #expect(lease.acquire())
            let native = CallbackDrainingQueue(lease: lease)
            let audio = AsyncThrowingStream<MicrophoneEvent, Error>.makeStream()
            let received = AsyncStream<Void>.makeStream()
            let stopped = AsyncStream<Void>.makeStream()
            let stops = Mutex(0)
            let session = SelectedMicrophoneSession(native: native, deviceAvailable: { true },
                deviceChanges: { AsyncStream { $0.finish() } }, continuation: audio.continuation,
                onStopped: {
                    stops.withLock { $0 += 1 }
                    lease.release()
                    stopped.continuation.yield(())
                })
            audio.continuation.onTermination = { _ in session.stop() }
            session.start()
            let consumer = Task {
                for try await event in audio.stream {
                    if case .chunk = event { received.continuation.yield(()) }
                }
            }
            var chunks = received.stream.makeAsyncIterator()
            _ = await chunks.next()
            consumer.cancel()
            try await consumer.value
            // Explicit stop can race stream termination; teardown must remain once-only.
            session.stop()
            var completions = stopped.stream.makeAsyncIterator()
            _ = await completions.next()
            #expect(native.callbackDrained)
            #expect(native.pendingBufferRejected)
            #expect(native.leaseHeldDuringStop)
            #expect(native.stopCount == 1)
            #expect(stops.withLock { $0 } == 1)
        }
        #expect(lease.acquire())
        lease.release()
    }

    @Test("startup and callback failures release ownership before publishing the error", arguments: [true, false])
    func failedCapture(duringStartup: Bool) async {
        let lease = MicrophoneCaptureLease()
        #expect(lease.acquire())
        let native = CallbackDrainingQueue(lease: lease, failStart: duringStartup, failCallback: !duringStartup)
        let audio = AsyncThrowingStream<MicrophoneEvent, Error>.makeStream()
        let session = SelectedMicrophoneSession(native: native, deviceAvailable: { true },
            deviceChanges: { AsyncStream { $0.finish() } }, continuation: audio.continuation,
            onStopped: { lease.release() })
        audio.continuation.onTermination = { _ in session.stop() }
        session.start()
        do {
            for try await _ in audio.stream { Issue.record("Failed capture must not deliver audio") }
            Issue.record("Expected capture error")
        } catch {
            #expect(error as? MicrophoneError == .engineFailed("test capture failure"))
        }
        #expect(native.callbackDrained)
        #expect(native.pendingBufferRejected)
        #expect(native.leaseHeldDuringStop)
        #expect(lease.acquire())
        lease.release()
    }
}

/// Models AudioQueue's synchronous stop: disposal cannot finish until queued callbacks return.
/// The deadline is only a deadlock safeguard; ordering uses callback completion, never sleeps.
private final class CallbackDrainingQueue: SelectedMicrophoneQueuing {
    private struct State {
        var queue: DispatchQueue?
        var receive: (@Sendable (Result<[Float], MicrophoneError>) -> Bool)?
        var drained = false
        var rejected = false
        var leaseHeld = false
        var stops = 0
    }
    private let state = Mutex(State())
    private let lease: MicrophoneCaptureLease
    private let failStart: Bool
    private let failCallback: Bool
    init(lease: MicrophoneCaptureLease, failStart: Bool = false, failCallback: Bool = false) {
        self.lease = lease
        self.failStart = failStart
        self.failCallback = failCallback
    }
    var callbackDrained: Bool { state.withLock { $0.drained } }
    var pendingBufferRejected: Bool { state.withLock { $0.rejected } }
    var leaseHeldDuringStop: Bool { state.withLock { $0.leaseHeld } }
    var stopCount: Int { state.withLock { $0.stops } }

    func start(on queue: DispatchQueue,
               receive: @escaping @Sendable (Result<[Float], MicrophoneError>) -> Bool) throws {
        state.withLock { $0.queue = queue; $0.receive = receive }
        if failStart { throw MicrophoneError.engineFailed("test capture failure") }
        queue.async { [failCallback] in
            _ = receive(failCallback ? .failure(.engineFailed("test capture failure"))
                        : .success([Float](repeating: 0.1, count: 1600)))
        }
    }

    func stop() {
        let (queue, receive) = state.withLock { value in
            value.stops += 1
            return (value.queue, value.receive)
        }
        let done = DispatchSemaphore(value: 0)
        queue?.async { [self] in
            let held = !lease.acquire()
            if !held { lease.release() }
            let accepted = receive?(.success([Float](repeating: 0.1, count: 1600))) ?? false
            state.withLock { $0.rejected = !accepted; $0.leaseHeld = held }
            done.signal()
        }
        let drained = done.wait(timeout: .now() + 2) == .success
        state.withLock { $0.drained = drained }
    }
}
