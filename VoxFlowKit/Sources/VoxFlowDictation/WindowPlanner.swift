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
        if buffered >= maxWindow || (buffered >= minWindow && silentTail >= trailingSilence) {
            return cut()
        }
        return nil
    }

    public mutating func flush() -> Window? {
        // A short remainder is left buffered rather than dropped, so a later append can top it
        // up past `minFlush` (e.g. two separate flush() calls straddling a pause in the feed).
        if Double(buffer.count) / AudioSamples.sampleRate >= minFlush {
            return cut()
        }
        return nil
    }

    private mutating func cut() -> Window {
        let window = Window(samples: AudioSamples(buffer), startOffset: consumed)
        consumed += Double(buffer.count) / AudioSamples.sampleRate
        buffer.removeAll(keepingCapacity: true)
        silentTail = 0
        return window
    }
}
