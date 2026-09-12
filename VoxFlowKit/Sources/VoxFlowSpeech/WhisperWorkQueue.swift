import Foundation
import Synchronization

/// Runs synchronous native operations away from cooperative executor threads.
final class WhisperWorkQueue: Sendable {
    enum Priority: Sendable { case dictation, file }
    private struct Work: Sendable { let priority: Priority; let body: @Sendable () -> Void }
    private struct State: Sendable { var running = false; var pending: [Work] = [] }
    private final class Cancellation: Sendable {
        let flag = Mutex(false)
        func check() throws { if flag.withLock({ $0 }) { throw CancellationError() } }
        func cancel() { flag.withLock { $0 = true } }
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "dev.artemsem.voxflow.whisper", qos: .userInitiated)
    var pendingCount: Int { state.withLock { $0.pending.count } }

    func enqueue(priority: Priority, _ body: @escaping @Sendable () -> Void) {
        let work = Work(priority: priority, body: body)
        let startNow = state.withLock { state in
            if state.running { state.pending.append(work); return false }
            state.running = true
            return true
        }
        if startNow { start(work) }
    }

    private func start(_ work: Work) {
        queue.async {
            work.body()
            let next: Work? = self.state.withLock { state in
                guard !state.pending.isEmpty else { state.running = false; return nil }
                let index = state.pending.firstIndex { $0.priority == .dictation } ?? 0
                return state.pending.remove(at: index)
            }
            if let next { self.start(next) }
        }
    }

    // Register work before yielding the caller's actor. Engine unload relies on every captured
    // native context being queued before another actor operation can enqueue its release.
    func run<T: Sendable>(priority: Priority, isolation: isolated (any Actor)? = #isolation,
                         _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(priority: priority) {
                    do { try cancellation.check(); continuation.resume(returning: try body()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
