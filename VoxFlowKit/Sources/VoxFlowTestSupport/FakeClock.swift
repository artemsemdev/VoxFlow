import Foundation
import Synchronization
import VoxFlowCore

/// Manual clock: time moves only through `advance(by:)`, which resumes sleepers in deadline order.
public final class FakeClock: MonotonicClock, Sendable {
    private struct Sleeper: Sendable { let id: UUID; let deadline: TimeInterval; let continuation: CheckedContinuation<Void, any Error> }
    private struct State: Sendable { var now: TimeInterval = 0; var sleepers: [Sleeper] = []; var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = [] }
    private let state = Mutex(State())

    public init() {}

    public func now() -> TimeInterval { state.withLock { $0.now } }
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(for seconds: TimeInterval) async throws {
        try Task.checkCancellation()   // already-cancelled callers must not register a sleeper `advance` would resume
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let waiters: [CheckedContinuation<Void, Never>] = state.withLock { s in
                    s.sleepers.append(Sleeper(id: id, deadline: s.now + seconds, continuation: continuation))
                    let ready = s.waiters.filter { $0.count <= s.sleepers.count }
                    s.waiters.removeAll { $0.count <= s.sleepers.count }
                    return ready.map(\.continuation)
                }
                waiters.forEach { $0.resume() }
            }
        } onCancel: {
            let cancelled = state.withLock { s -> Sleeper? in
                guard let index = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Suspends until at least `count` tasks are parked in `sleep`.
    public func waitForSleepers(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { s -> Bool in
                if s.sleepers.count >= count { return true }
                s.waiters.append((count, continuation)); return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Moves time forward and resumes every sleeper whose deadline has passed, earliest first.
    public func advance(by seconds: TimeInterval) async {
        let due = state.withLock { s -> [Sleeper] in
            s.now += seconds
            let due = s.sleepers.filter { $0.deadline <= s.now }.sorted { $0.deadline < $1.deadline }
            s.sleepers.removeAll { $0.deadline <= s.now }
            return due
        }
        due.forEach { $0.continuation.resume() }
        await Task.yield()
    }
}
