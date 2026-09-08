import Foundation

/// Audio in the one internal format the engine accepts: 16 kHz, mono, Float32 in -1...1.
public struct AudioSamples: Sendable, Equatable {
    public static let sampleRate: Double = 16_000

    public var samples: [Float]

    public init(_ samples: [Float]) {
        self.samples = samples
    }

    public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
    public var isEmpty: Bool { samples.isEmpty }
}
