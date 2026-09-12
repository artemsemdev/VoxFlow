import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowAudio

@Suite("Pull-based audio reader", .timeLimit(.minutes(1)))
struct AudioReaderTests {
    @Test("opening a reader does no sample reads; one requested chunk does not decode the rest")
    func lazyReads() throws {
        let directory = TemporaryDirectory()
        let url = directory.file("long.wav")
        try FixtureAudio.writeSine(to: url, seconds: 20, sampleRate: 16_000, channels: 1)
        let reads = Mutex(0)
        let decoder: any AudioDecoding = AudioDecoder { file, buffer, count in
            reads.withLock { $0 += 1 }
            try file.read(into: buffer, frameCount: count)
        }
        var reader = try decoder.open(url, progress: { _ in })
        #expect(reads.withLock { $0 } == 0)
        #expect(reader.estimatedSampleCount == 320_000)
        let first = try reader.read(upTo: 8_000)
        let chunk = try #require(first)
        #expect(chunk.samples.count == 8_000)
        #expect(reads.withLock { $0 } == 1)
    }

    @Test("small reads preserve resampler tails and channel averaging", arguments: ["wav", "m4a", "mp3"])
    func chunkedMatchesFullDecode(ext: String) throws {
        let directory = TemporaryDirectory()
        let url: URL
        if ext == "mp3" {
            url = Bundle.module.url(forResource: "tone-1s", withExtension: "mp3", subdirectory: "Fixtures")!
        } else {
            url = directory.file("tone.\(ext)")
            if ext == "m4a" { try FixtureAudio.writeAAC(to: url, seconds: 2) }
            else { try FixtureAudio.writeSine(to: url, seconds: 2, sampleRate: 44_100, channels: 2) }
        }
        let decoder = AudioDecoder()
        let reference = try decoder.decode(url)
        let progress = Mutex<[Double]>([])
        var reader = try decoder.open(url) { value in progress.withLock { $0.append(value) } }
        var samples: [Float] = []
        while let chunk = try reader.read(upTo: 137) {
            #expect(!chunk.isEmpty && chunk.samples.count <= 137)
            samples.append(contentsOf: chunk.samples)
        }
        #expect(samples.count == reference.samples.count)
        #expect(zip(samples, reference.samples).allSatisfy { abs($0 - $1) < 0.00001 })
        #expect(progress.withLock { $0 == $0.sorted() && $0.last == 1 })
        let afterEnd = try reader.read(upTo: 137)
        #expect(afterEnd == nil)
    }
}
