import Foundation
import Synchronization

/// Serializes input commands, while allowing Escape to invalidate queued or suspended preparation.
@MainActor
final class DictationCommandQueue {
    private struct Command: Sendable {
        let generation: UInt64?
        let operation: @Sendable () async -> Void
    }
    private let stream: AsyncStream<Command>
    private let continuation: AsyncStream<Command>.Continuation
    private nonisolated let runner = Mutex<Task<Void, Never>?>(nil)
    private nonisolated let preparation = Preparation()

    init() { (stream, continuation) = AsyncStream<Command>.makeStream() }

    func start() {
        guard runner.withLock({ $0 == nil }) else { return }
        let task = Task { [stream, preparation] in
            for await command in stream {
                guard !Task.isCancelled else { break }
                // Created on the main actor: install cancellation before this child can run.
                let operation = Task {
                    guard !Task.isCancelled else { return }
                    await command.operation()
                }
                if let generation = command.generation { preparation.install(operation, generation: generation) }
                await withTaskCancellationHandler {
                    await operation.value
                } onCancel: { operation.cancel() }
                preparation.clear()
            }
        }
        runner.withLock { $0 = task }
    }

    func send(preparation: Bool = false, _ operation: @escaping @Sendable () async -> Void) {
        continuation.yield(Command(generation: preparation ? self.preparation.generation : nil, operation: operation))
    }

    func cancelPreparations() { preparation.cancel() }

    deinit {
        runner.withLock { $0?.cancel() }
        preparation.cancel()
        continuation.finish()
    }

    private final class Preparation: Sendable {
        private struct State {
            var generation: UInt64 = 0
            var task: Task<Void, Never>?
        }
        private let state = Mutex(State())
        var generation: UInt64 { state.withLock { $0.generation } }
        func install(_ task: Task<Void, Never>, generation: UInt64) {
            let stale = state.withLock { state in
                guard state.generation == generation else { return true }
                state.task = task
                return false
            }
            if stale { task.cancel() }
        }
        func clear() { state.withLock { $0.task = nil } }
        func cancel() {
            let task = state.withLock { state in
                state.generation &+= 1
                let task = state.task
                state.task = nil
                return task
            }
            task?.cancel()
        }
    }
}
