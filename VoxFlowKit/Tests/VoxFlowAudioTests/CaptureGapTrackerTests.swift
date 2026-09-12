import Testing
import VoxFlowCore
@testable import VoxFlowAudio

@Suite("CaptureGapTracker")
struct CaptureGapTrackerTests {
    private func chunk() -> AudioChunk { AudioChunk(samples: [0.25]) }

    @Test("the first converted chunk after restart carries the monotonic gap once")
    func firstChunkAfterRestart() {
        var tracker = CaptureGapTracker()
        let token = tracker.begin(at: 1)
        var empty: [AudioChunk] = []
        tracker.apply(to: &empty, token: token, resumedAt: 1.125)

        var converted = [chunk(), chunk()]
        tracker.apply(to: &converted, token: token, resumedAt: 1.25)
        #expect(converted.map(\.precedingGap) == [0.125, 0])

        var later = [chunk()]
        tracker.apply(to: &later, token: token, resumedAt: 2)
        #expect(later[0].precedingGap == 0)
    }

    @Test("repeated switches preserve the earliest interruption and reject stale callbacks")
    func repeatedSwitches() {
        var tracker = CaptureGapTracker()
        let stale = tracker.begin(at: 1)
        let current = tracker.begin(at: 1.4)
        var staleChunks = [chunk()]
        tracker.apply(to: &staleChunks, token: stale, resumedAt: 1.5)
        #expect(staleChunks[0].precedingGap == 0)

        var currentChunks = [chunk()]
        tracker.apply(to: &currentChunks, token: current, resumedAt: 1.75)
        #expect(currentChunks[0].precedingGap == 0.75)
    }

    @Test("reset discards an unfinished restart")
    func reset() {
        var tracker = CaptureGapTracker()
        tracker.recordYielded(through: 5)
        let token = tracker.begin(at: 1)
        tracker.reset()
        var staleChunks = [chunk()]
        tracker.apply(to: &staleChunks, token: token, resumedAt: 2)
        #expect(staleChunks[0].precedingGap == 0)

        let fresh = tracker.begin(at: 1)
        var freshChunks = [chunk()]
        tracker.apply(to: &freshChunks, token: fresh, resumedAt: 2)
        #expect(freshChunks[0].precedingGap == 1)
    }

    @Test("a new tap cannot inherit partial samples or yield from a stale generation")
    func perTapIsolation() {
        var tracker = CaptureGapTracker()
        var oldTap = CaptureAudioTap(token: tracker.activeToken, chunkSamples: 4)
        #expect(oldTap.append([1, 1], resumedAt: 0, tracker: &tracker).isEmpty)

        let replacement = tracker.begin(at: 1)
        var newTap = CaptureAudioTap(token: replacement, chunkSamples: 4)
        let replacementChunks = newTap.append([2, 2, 2, 2], resumedAt: 1.5, tracker: &tracker)
        #expect(replacementChunks.map(\.samples) == [[2, 2, 2, 2]])
        #expect(replacementChunks.map(\.precedingGap) == [0.5])
        #expect(oldTap.append([1, 1], resumedAt: 2, tracker: &tracker).isEmpty)
    }

    @Test("restart flushes pending audio and measures the next gap from its real end")
    func pendingAudioBoundary() throws {
        var tracker = CaptureGapTracker()
        var oldTap = CaptureAudioTap(token: tracker.activeToken, chunkSamples: 1_600)
        #expect(oldTap.append([Float](repeating: 1, count: 1_600), resumedAt: 0.9,
                              tracker: &tracker).count == 1)
        #expect(oldTap.append([Float](repeating: 2, count: 1_280), resumedAt: 1,
                              tracker: &tracker).isEmpty)
        let flushed = oldTap.flush(tracker: &tracker)
        let tail = try #require(flushed)
        #expect(tail.samples.count == 1_280)

        let replacement = tracker.begin(at: 1.04)
        var newTap = CaptureAudioTap(token: replacement, chunkSamples: 1_600)
        let chunks = newTap.append([Float](repeating: 3, count: 1_600), resumedAt: 1.2,
                                   tracker: &tracker)
        let resumed = try #require(chunks.first)
        #expect(abs(resumed.precedingGap - 0.12) < 0.000_001)
    }

    @Test("a partial first buffer retains its timestamp when restart flushes it")
    func partialFirstBufferTimestamp() throws {
        var tracker = CaptureGapTracker()
        let token = tracker.begin(at: 1)
        var tap = CaptureAudioTap(token: token, chunkSamples: 1_600)
        #expect(tap.append([Float](repeating: 1, count: 800), resumedAt: 1.5,
                           tracker: &tracker).isEmpty)
        let flushed = tap.flush(tracker: &tracker)
        let tail = try #require(flushed)
        #expect(tail.samples.count == 800)
        #expect(abs(tail.precedingGap - 0.5) < 0.000_001)
    }

    @Test("a late dropped callback remains part of the gap after the last yielded audio")
    func droppedOldBufferBoundary() throws {
        var tracker = CaptureGapTracker()
        tracker.recordYielded(through: 1)
        var oldTap = CaptureAudioTap(token: tracker.activeToken, chunkSamples: 1_600)
        let replacement = tracker.begin(at: 1.08)
        #expect(oldTap.append([Float](repeating: 1, count: 1_600), resumedAt: 1.08,
                              tracker: &tracker).isEmpty)

        var newTap = CaptureAudioTap(token: replacement, chunkSamples: 1_600)
        let chunks = newTap.append([Float](repeating: 2, count: 1_600), resumedAt: 1.2,
                                   tracker: &tracker)
        let resumed = try #require(chunks.first)
        #expect(abs(resumed.precedingGap - 0.2) < 0.000_001)
    }

    @Test("yielded audio after the notification prevents overlap in the reported gap")
    func yieldedBoundaryAfterNotification() throws {
        var tracker = CaptureGapTracker()
        tracker.recordYielded(through: 1.1)
        let replacement = tracker.begin(at: 1.08)
        var tap = CaptureAudioTap(token: replacement, chunkSamples: 1_600)
        let chunks = tap.append([Float](repeating: 1, count: 1_600), resumedAt: 1.2,
                                tracker: &tracker)
        let resumed = try #require(chunks.first)
        #expect(abs(resumed.precedingGap - 0.1) < 0.000_001)
    }
}
