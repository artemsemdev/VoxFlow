import Foundation

/// "About 3 min left": progress rate over the last `window` seconds, extrapolated (design 3d).
public struct ETAEstimator: Sendable, Equatable {
    public let window: TimeInterval
    private var samples: [(progress: Double, time: TimeInterval)] = []

    public init(window: TimeInterval = 10) { self.window = window }

    public mutating func record(progress: Double, at time: TimeInterval) {
        samples.append((progress, time))
        let cutoff = time - window
        // Keep one sample at or before the cutoff so the rate spans the whole window.
        while samples.count > 2, samples[1].time <= cutoff { samples.removeFirst() }
    }

    public var secondsRemaining: TimeInterval? {
        guard let last = samples.last else { return nil }
        if last.progress >= 1 { return 0 }
        guard let first = samples.first, last.time > first.time else { return nil }
        let rate = (last.progress - first.progress) / (last.time - first.time)
        guard rate > 0 else { return nil }
        return (1 - last.progress) / rate
    }

    public static func == (lhs: ETAEstimator, rhs: ETAEstimator) -> Bool {
        lhs.window == rhs.window && lhs.samples.map(\.progress) == rhs.samples.map(\.progress) && lhs.samples.map(\.time) == rhs.samples.map(\.time)
    }
}
