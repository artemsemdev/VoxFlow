import Foundation
import VoxFlowCore

/// Cuts a live feed into transcription windows. Pure; the transcriber owns one per dictation.
public struct WindowPlanner: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        public var samples: AudioSamples
        public var startOffset: TimeInterval
    }

    public var minWindow: TimeInterval = 3
    public var maxWindow: TimeInterval = 10
    public var trailingSilence: TimeInterval = 0.4
    public var minFlush: TimeInterval = 0.3
    public var voiceRMS: Float

    private var buffer: [Float] = []
    /// Seconds of trailing audio below `voiceRMS`.
    private var silentTail: TimeInterval = 0
    private var consumed: TimeInterval = 0

    public init(voiceRMS: Float = DictationDefaults.voiceRMS) { self.voiceRMS = voiceRMS }

    public mutating func append(_ chunk: AudioChunk) -> Window? {
        buffer.append(contentsOf: chunk.samples)
        silentTail = chunk.rms < voiceRMS ? silentTail + chunk.duration : 0
        let buffered = Double(buffer.count) / AudioSamples.sampleRate
        if buffered >= maxWindow { return cut(at: lastPauseEnd()) }
        if buffered >= minWindow && silentTail >= trailingSilence {
            return cut()
        }
        return nil
    }

    /// Ends the pre-switch window and advances its absolute timeline without adding fake samples.
    public mutating func interrupt(by gap: TimeInterval) -> Window? {
        guard gap > 0 else { return nil }
        let interrupted = buffer.isEmpty ? nil : cut()
        consumed += gap
        return interrupted
    }

    public mutating func flush() -> Window? {
        // A short remainder is left buffered rather than dropped, so a later append can top it
        // up past `minFlush` (e.g. two separate flush() calls straddling a pause in the feed).
        if Double(buffer.count) / AudioSamples.sampleRate >= minFlush {
            return cut()
        }
        return nil
    }

    /// At the latency limit, prefer a short internal pause to splitting a word. The suffix is
    /// retained verbatim for the next window; no overlap, dropped samples or duplicated words.
    private func lastPauseEnd() -> Int {
        let frame = Int(0.02 * AudioSamples.sampleRate)
        let minimum = Int(minWindow * AudioSamples.sampleRate)
        let pauseSamples = Int(0.2 * AudioSamples.sampleRate)
        var quietSamples = 0
        var quietEnd = buffer.count
        for end in stride(from: buffer.count, through: minimum + frame, by: -frame) {
            let energy = buffer[(end - frame)..<end].reduce(Float(0)) { $0 + $1 * $1 }
            if energy / Float(frame) < voiceRMS * voiceRMS {
                if quietSamples == 0 { quietEnd = end }
                quietSamples += frame
                // A shorter voiced suffix would be discarded by flush(); keep it in this window.
                let remaining = buffer.count - quietEnd
                if quietSamples >= pauseSamples && (remaining == 0 || Double(remaining) / AudioSamples.sampleRate >= minFlush) {
                    return quietEnd
                }
            } else {
                quietSamples = 0
            }
        }
        return buffer.count
    }

    private mutating func cut(at end: Int? = nil) -> Window {
        let count = end ?? buffer.count
        let window = Window(samples: AudioSamples(Array(buffer.prefix(count))), startOffset: consumed)
        consumed += Double(count) / AudioSamples.sampleRate
        buffer.removeFirst(count)
        silentTail = min(silentTail, Double(buffer.count) / AudioSamples.sampleRate)
        return window
    }
}
