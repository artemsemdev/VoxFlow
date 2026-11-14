import Foundation
import VoxFlowCore

/// Mutable session state and callbacks are confined to `queue`. Once stopped, callbacks reject
/// buffers and native ownership passes to `shutdownQueue` until synchronous disposal completes.
final class SelectedMicrophoneSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.artemsem.voxflow.selected-microphone")
    private let shutdownQueue = DispatchQueue(label: "dev.artemsem.voxflow.selected-microphone.shutdown")
    private let native: any SelectedMicrophoneQueuing
    private let deviceAvailable: @Sendable () -> Bool
    private let deviceChanges: @Sendable () -> AsyncStream<Void>
    private let continuation: AsyncThrowingStream<MicrophoneEvent, Error>.Continuation
    private let onStopped: @Sendable () -> Void
    private var changes: Task<Void, Never>?
    private var stopped = false
    private var chunker: AudioChunker

    convenience init(uid: String, chunkSeconds: Double,
                     classifyError: @escaping @Sendable (String) -> MicrophoneError,
                     continuation: AsyncThrowingStream<MicrophoneEvent, Error>.Continuation,
                     onStopped: @escaping @Sendable () -> Void) {
        self.init(native: SelectedMicrophoneQueue(uid: uid, classifyError: classifyError),
                  deviceAvailable: { AudioInputDevices.deviceID(forUID: uid) != nil },
                  deviceChanges: { AudioInputDevices.changes() }, chunkSeconds: chunkSeconds,
                  continuation: continuation, onStopped: onStopped)
    }

    init(native: any SelectedMicrophoneQueuing,
         deviceAvailable: @escaping @Sendable () -> Bool,
         deviceChanges: @escaping @Sendable () -> AsyncStream<Void>, chunkSeconds: Double = 0.1,
         continuation: AsyncThrowingStream<MicrophoneEvent, Error>.Continuation,
         onStopped: @escaping @Sendable () -> Void) {
        self.native = native
        self.deviceAvailable = deviceAvailable
        self.deviceChanges = deviceChanges
        self.continuation = continuation
        self.onStopped = onStopped
        chunker = AudioChunker(seconds: chunkSeconds)
    }

    func start() {
        queue.async { [self] in
            guard !stopped else { return }
            do {
                try requireDevice()
                let events = deviceChanges()
                changes = Task { [weak self] in
                    for await _ in events {
                        guard !Task.isCancelled, let self else { return }
                        self.queue.async {
                            guard !self.stopped else { return }
                            do { try self.requireDevice() } catch { self.fail(error) }
                        }
                    }
                }
                try native.start(on: queue) { [weak self] result in self?.receive(result) ?? false }
            } catch { fail(error) }
        }
    }

    private func receive(_ result: Result<[Float], MicrophoneError>) -> Bool {
        guard !stopped else { return false }
        do {
            try requireDevice()
            for chunk in chunker.append(try result.get()) { continuation.yield(.chunk(chunk)) }
            return true
        } catch {
            queue.async { [self] in fail(error) }
            return false
        }
    }

    private func requireDevice() throws {
        guard deviceAvailable() else { throw MicrophoneError.noInputDevice }
    }

    private func fail(_ error: Error) {
        stopInternal(error: error)
    }

    func stop() { queue.async { [self] in stopInternal() } }

    private func stopInternal(error: Error? = nil) {
        guard !stopped else { return }
        stopped = true
        changes?.cancel(); changes = nil
        // Stop/Dispose wait for pending callbacks. Running them on the callback queue itself
        // prevents those callbacks from returning and holds the capture lease until timeouts.
        shutdownQueue.async { [native, onStopped, continuation] in
            native.stop()
            onStopped()
            if let error { continuation.finish(throwing: error) }
        }
    }
}
