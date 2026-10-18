import Foundation
import VoxFlowCore

/// Purges at `start()` and then every 24 h (design §5 "runs at launch and daily").
public actor RetentionRunner {
    public static let interval: TimeInterval = 86_400
    private let store: DictationStore
    private let policy: @Sendable () -> RetentionPolicy
    private let now: @Sendable () -> Date
    private let clock: any MonotonicClock
    private var task: Task<Void, Never>?
    private var passes = 0
    private var stopped = false
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    public init(store: DictationStore, policy: @escaping @Sendable () -> RetentionPolicy, now: @escaping @Sendable () -> Date, clock: any MonotonicClock) {
        self.store = store
        self.policy = policy
        self.now = now
        self.clock = clock
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self, clock] in
            while !Task.isCancelled {
                guard await self?.purge() != nil else { return }
                // The owner may release the runner during its daily sleep.
                do { try await clock.sleep(for: Self.interval) } catch { return }
            }
        }
    }

    deinit { task?.cancel() }

    /// Stops the run loop and resumes every pending `waitForPass` waiter (even one whose count will
    /// now never be reached) so a `stop()` racing a `waitForPass` returns instead of hanging forever;
    /// callers should treat `waitForPass` returning after `stop()` as "no more passes are coming",
    /// not as proof the requested count was actually reached.
    public func stop() {
        task?.cancel(); task = nil
        stopped = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.1.resume() }
    }

    /// Suspends until at least `count` purge passes have run — or `stop()` is called first, in which
    /// case this returns early without the count having been reached (see `stop()`).
    public func waitForPass(_ count: Int) async {
        if passes >= count || stopped { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    private func purge() {
        if let cutoff = policy().cutoff(now: now()) { _ = try? store.deleteOlderThan(cutoff) }
        passes += 1
        let ready = waiters.filter { $0.0 <= passes }
        waiters.removeAll { $0.0 <= passes }
        ready.forEach { $0.1.resume() }
    }
}
