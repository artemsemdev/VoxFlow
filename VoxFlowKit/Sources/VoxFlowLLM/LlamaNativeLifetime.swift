import Foundation
import Synchronization

/// Registers one FIFO native release and lets every explicit caller await its completion.
/// The resource owner can request the same cleanup from deinit without capturing itself.
final class LlamaNativeLifetime: Sendable {
    private struct State {
        var scheduled = false
        var completed = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private enum Action { case complete, wait, enqueue }
    private let state = Mutex(State())
    private let queue: DispatchQueue
    private let free: @Sendable () -> Void

    init(queue: DispatchQueue, free: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.free = free
    }

    func release(isolation: isolated (any Actor)? = #isolation) async {
        await withCheckedContinuation { continuation in
            let action = state.withLock { value -> Action in
                if value.completed { return .complete }
                value.waiters.append(continuation)
                if value.scheduled { return .wait }
                value.scheduled = true
                return .enqueue
            }
            switch action {
            case .complete: continuation.resume()
            case .wait: break
            case .enqueue: enqueue()
            }
        }
    }

    func releaseInBackground() {
        let claimed = state.withLock { value in
            guard !value.scheduled else { return false }
            value.scheduled = true
            return true
        }
        if claimed { enqueue() }
    }

    private func enqueue() {
        queue.async { [self] in
            free()
            let waiters = state.withLock { value in
                value.completed = true
                let waiters = value.waiters
                value.waiters.removeAll()
                return waiters
            }
            for waiter in waiters { waiter.resume() }
        }
    }
}
