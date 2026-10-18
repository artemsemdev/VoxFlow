import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowAudio

@Suite("Audio decode cancellation", .timeLimit(.minutes(1)))
struct AudioDecoderCancellationTests {
    @Test("decode reports intermediate monotonic progress through its protocol")
    func intermediateProgress() throws {
        let directory = TemporaryDirectory()
        let url = directory.file("long.wav")
        try FixtureAudio.writeSine(to: url, seconds: 20, sampleRate: 44_100, channels: 2)
        let decoder: any AudioDecoding = AudioDecoder()
        let values = Mutex<[Double]>([])
        let audio = try decoder.decode(url) { value in values.withLock { $0.append(value) } }
        let reported = values.withLock { $0 }
        #expect(reported.first == 0)
        #expect(reported.contains { $0 > 0 && $0 < 1 })
        #expect(reported.last == 1 && reported == reported.sorted())
        #expect(reported.allSatisfy { (0...1).contains($0) })
        #expect(abs(audio.duration - 20) < 0.05)
    }

    @Test("an already cancelled task does not open or decode its file")
    func cancelledBeforeOpening() async {
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return Result { try AudioDecoder().decode(URL(fileURLWithPath: "/missing.wav")) }
        }
        let result = await operation.value
        #expect(throws: CancellationError.self) { _ = try result.get() }
    }

    @Test("cancellation after one read stops before another chunk and reports no completion")
    func cancelledBetweenChunks() async throws {
        let directory = TemporaryDirectory()
        let url = directory.file("long.wav")
        try FixtureAudio.writeSine(to: url, seconds: 20, sampleRate: 16_000, channels: 1)
        let handle = Mutex<Task<AudioSamples, Error>?>(nil)
        let reads = Mutex(0)
        let progress = Mutex<[Double]>([])
        let start = Gate()
        let decoder = AudioDecoder { file, buffer, count in
            reads.withLock { $0 += 1 }
            try file.read(into: buffer, frameCount: count)
            handle.withLock { $0?.cancel() }
        }
        let operation = Task {
            await start.wait()
            return try decoder.decode(url) { value in progress.withLock { $0.append(value) } }
        }
        handle.withLock { $0 = operation }
        await start.open()
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(reads.withLock { $0 } == 1)
        #expect(progress.withLock { !$0.contains(1) })
        handle.withLock { $0 = nil }
    }
}
