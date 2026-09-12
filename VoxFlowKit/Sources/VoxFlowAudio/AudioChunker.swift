import Foundation
import VoxFlowCore

/// Re-slices a stream of 16 kHz samples into equal chunks (the last one via `flush`).
public struct AudioChunker: Sendable, Equatable {
    public let chunkSamples: Int
    private var pending: [Float] = []
    var pendingSampleCount: Int { pending.count }

    public init(chunkSamples: Int) { self.chunkSamples = max(1, chunkSamples) }
    public init(seconds: Double) { self.init(chunkSamples: Int(seconds * AudioSamples.sampleRate)) }

    public mutating func append(_ samples: [Float]) -> [AudioChunk] {
        pending.append(contentsOf: samples)
        var out: [AudioChunk] = []
        while pending.count >= chunkSamples {
            out.append(AudioChunk(samples: Array(pending.prefix(chunkSamples))))
            pending.removeFirst(chunkSamples)
        }
        return out
    }

    public mutating func flush() -> AudioChunk? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return AudioChunk(samples: pending)
    }
}
