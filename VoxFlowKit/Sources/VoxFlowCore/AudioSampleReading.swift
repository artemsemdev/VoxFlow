import Foundation

/// A single-consumer cursor. The estimate is a progress hint; nil from read means actual EOF.
public protocol AudioSampleReading: Sendable {
    var estimatedSampleCount: Int { get }
    mutating func read(upTo sampleCount: Int) throws -> AudioSamples?
}

/// Compatibility for decoders that still return a whole buffer. Native file decoding overrides
/// open(_:progress:) with a bounded reader and does not use this in-memory adapter.
struct BufferedAudioReader: AudioSampleReading {
    let estimatedSampleCount: Int
    private let samples: [Float]
    private var offset = 0

    init(_ audio: AudioSamples) {
        samples = audio.samples
        estimatedSampleCount = audio.samples.count
    }

    mutating func read(upTo sampleCount: Int) throws -> AudioSamples? {
        precondition(sampleCount > 0)
        try Task.checkCancellation()
        guard offset < samples.count else { return nil }
        let end = offset + min(sampleCount, samples.count - offset)
        defer { offset = end }
        return AudioSamples(Array(samples[offset..<end]))
    }
}
