import Testing
@testable import VoxFlowFiles

@Suite("ETAEstimator")
struct ETAEstimatorTests {
    @Test("needs two samples, then extrapolates the recent rate")
    func extrapolates() {
        var eta = ETAEstimator(window: 10)
        eta.record(progress: 0, at: 0)
        #expect(eta.secondsRemaining == nil)
        eta.record(progress: 0.25, at: 10)      // 0.025/s → 30 s for the remaining 0.75
        #expect(eta.secondsRemaining == 30)
    }

    @Test("only the last window of samples counts, so a slow start does not dominate")
    func windowed() {
        var eta = ETAEstimator(window: 10)
        eta.record(progress: 0, at: 0)
        eta.record(progress: 0.1, at: 20)       // slow
        eta.record(progress: 0.5, at: 30)       // fast: 0.04/s over the last 10 s → 12.5 s left
        #expect(eta.secondsRemaining == 12.5)
    }

    @Test("complete or stalled progress")
    func edges() {
        var eta = ETAEstimator(window: 10)
        eta.record(progress: 0.5, at: 0)
        eta.record(progress: 0.5, at: 5)
        #expect(eta.secondsRemaining == nil)    // no rate yet
        eta.record(progress: 1, at: 6)
        #expect(eta.secondsRemaining == 0)
    }
}
