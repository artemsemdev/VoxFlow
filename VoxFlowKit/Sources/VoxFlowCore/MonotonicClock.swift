import Foundation

/// Time for the dictation loop: monotonic seconds plus a cancellable sleep. Fakes advance it by hand.
public protocol MonotonicClock: Sendable {
    func now() -> TimeInterval
    func sleep(for seconds: TimeInterval) async throws
}

public struct SystemMonotonicClock: MonotonicClock {
    private let origin = ContinuousClock.now

    public init() {}

    public func now() -> TimeInterval {
        let elapsed = origin.duration(to: ContinuousClock.now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}
