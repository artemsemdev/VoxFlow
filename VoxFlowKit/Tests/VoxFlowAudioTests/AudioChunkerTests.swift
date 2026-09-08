import Foundation
import Testing
import VoxFlowCore
@testable import VoxFlowAudio

@Suite("AudioChunker")
struct AudioChunkerTests {
    @Test("emits fixed-size chunks, carries the remainder, flushes the tail")
    func chunks() {
        var chunker = AudioChunker(chunkSamples: 4)
        #expect(chunker.append([1, 1, 1]).isEmpty)
        let out = chunker.append([1, 0, 0, 0, 0, 0.5])
        #expect(out.map(\.samples) == [[1, 1, 1, 1], [0, 0, 0, 0]])
        #expect(chunker.flush()?.samples == [0.5])
        #expect(chunker.flush() == nil)
    }

    @Test("chunk length for 100 ms at 16 kHz is 1600 samples")
    func sizing() {
        #expect(AudioChunker(seconds: 0.1).chunkSamples == 1600)
    }
}
