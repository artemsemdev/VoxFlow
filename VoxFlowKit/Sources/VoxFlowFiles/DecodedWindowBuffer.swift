import Foundation
import VoxFlowCore

/// Retains only the detection prefix or the next transcription window's lookahead.
struct DecodedWindowBuffer {
    var source: any AudioSampleReading
    private(set) var samples: [Float] = []
    private(set) var reachedEnd = false
    private(set) var decodedCount = 0

    mutating func fill(upTo count: Int) throws {
        while samples.count < count && !reachedEnd {
            try Task.checkCancellation()
            let requested = count - samples.count
            guard let audio = try source.read(upTo: requested) else { reachedEnd = true; break }
            guard !audio.isEmpty, audio.samples.count <= requested else {
                throw AudioDecodingError.decodeFailed("decoder returned an invalid chunk size")
            }
            decodedCount += audio.samples.count
            samples.append(contentsOf: audio.samples)
        }
    }

    mutating func consume(_ count: Int) { samples.removeFirst(count) }
}
