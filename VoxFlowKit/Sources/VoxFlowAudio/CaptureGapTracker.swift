import Foundation
import Synchronization
import VoxFlowCore

/// Matches an engine restart with its first converted audio, ignoring stale tap callbacks.
struct CaptureGapTracker: Sendable, Equatable {
    private struct Pending: Sendable, Equatable {
        var token: UInt64
        var startedAt: TimeInterval
        var resumedAt: TimeInterval?
    }

    private var nextToken: UInt64 = 0
    private var pending: Pending?
    private var lastYieldedHostBoundary: TimeInterval?

    var activeToken: UInt64 { nextToken }

    func isActive(_ token: UInt64) -> Bool { token == nextToken }

    mutating func recordYielded(through hostTime: TimeInterval) {
        guard hostTime.isFinite else { return }
        lastYieldedHostBoundary = max(lastYieldedHostBoundary ?? hostTime, hostTime)
    }

    mutating func begin(at: TimeInterval) -> UInt64 {
        nextToken &+= 1
        pending = Pending(token: nextToken,
                          startedAt: pending?.startedAt ?? lastYieldedHostBoundary ?? at,
                          resumedAt: nil)
        return nextToken
    }

    mutating func apply(to chunks: inout [AudioChunk], token: UInt64, resumedAt: TimeInterval) {
        guard var pending, pending.token == token, isActive(token) else { return }
        if pending.resumedAt == nil { pending.resumedAt = resumedAt }
        self.pending = pending
        guard !chunks.isEmpty, let firstSampleAt = pending.resumedAt else { return }
        self.pending = nil
        guard firstSampleAt >= pending.startedAt else { return }
        chunks[0].precedingGap += firstSampleAt - pending.startedAt
    }

    mutating func reset() {
        nextToken &+= 1
        pending = nil
        lastYieldedHostBoundary = nil
    }
}

/// Per-installed-tap sample buffer. A stale generation is dropped before it can mutate or yield.
struct CaptureAudioTap: Sendable, Equatable {
    let token: UInt64
    private var chunker: AudioChunker
    private var lastBufferedHostEnd: TimeInterval?

    init(token: UInt64, chunkSamples: Int) {
        self.token = token
        chunker = AudioChunker(chunkSamples: chunkSamples)
    }

    mutating func append(_ samples: [Float], resumedAt: TimeInterval,
                         tracker: inout CaptureGapTracker) -> [AudioChunk] {
        guard tracker.isActive(token) else { return [] }
        var chunks = chunker.append(samples)
        tracker.apply(to: &chunks, token: token, resumedAt: resumedAt)
        let bufferEnd = resumedAt + Double(samples.count) / AudioSamples.sampleRate
        lastBufferedHostEnd = max(lastBufferedHostEnd ?? bufferEnd, bufferEnd)
        if !chunks.isEmpty {
            tracker.recordYielded(through: bufferEnd - Double(chunker.pendingSampleCount) / AudioSamples.sampleRate)
        }
        return chunks
    }

    mutating func flush(tracker: inout CaptureGapTracker) -> AudioChunk? {
        guard tracker.isActive(token), var chunk = chunker.flush() else { return nil }
        var chunks = [chunk]
        tracker.apply(to: &chunks, token: token, resumedAt: lastBufferedHostEnd ?? 0)
        chunk = chunks[0]
        if let lastBufferedHostEnd { tracker.recordYielded(through: lastBufferedHostEnd) }
        return chunk
    }
}

/// Reference identity lets the render callback and session queue retain the same noncopyable mutex.
final class CaptureAudioTapBox: Sendable {
    private let tap: Mutex<CaptureAudioTap>

    init(token: UInt64, chunkSamples: Int) {
        tap = Mutex(CaptureAudioTap(token: token, chunkSamples: chunkSamples))
    }

    func append(_ samples: [Float], resumedAt: TimeInterval,
                tracker: inout CaptureGapTracker) -> [AudioChunk] {
        tap.withLock { $0.append(samples, resumedAt: resumedAt, tracker: &tracker) }
    }

    func flush(tracker: inout CaptureGapTracker) -> AudioChunk? {
        tap.withLock { $0.flush(tracker: &tracker) }
    }
}
