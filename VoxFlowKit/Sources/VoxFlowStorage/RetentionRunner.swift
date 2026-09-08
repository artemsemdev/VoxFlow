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
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    public init(store: DictationStore, policy: @escaping @Sendable () -> RetentionPolicy, now: @escaping @Sendable () -> Date, clock: any MonotonicClock) {
        self.store = store
        self.policy = policy
        self.now = now
        self.clock = clock
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.purge()
                do { try await self.clock.sleep(for: Self.interval) } catch { return }
            }
        }
    }

    public func stop() { task?.cancel(); task = nil }

    /// Suspends until at least `count` purge passes have run (tests).
    public func waitForPass(_ count: Int) async {
        if passes >= count { return }
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
