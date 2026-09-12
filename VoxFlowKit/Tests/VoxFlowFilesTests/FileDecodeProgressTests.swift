import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowFiles

@Suite("File decode progress", .timeLimit(.minutes(1)))
struct FileDecodeProgressTests {
    private let url = URL(fileURLWithPath: "/tmp/long.wav")

    @Test("decoder progress occupies the first five percent of file work")
    func progressShare() async throws {
        let engine = FakeSpeechEngine(script: [])
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let transcriber = FileTranscriber(decoder: ProgressDecoder(), engine: engine, modelID: "m")
        let progress = Progress()
        _ = try await transcriber.transcribe(url, options: TranscriptionOptions(language: "en")) { if case .progress(let value) = $0 { progress.append(value) } }
        let expected = [0, 0.0125, 0.025, 0.0375, 0.05]
        #expect(progress.values.count >= expected.count)
        #expect(zip(progress.values, expected).allSatisfy { abs($0 - $1) < 0.000001 })
        #expect(progress.values == progress.values.sorted() && progress.values.last == 1)
    }

    @Test("decoder cancellation is the same typed cancellation as inference")
    func cancelledDecode() async {
        let transcriber = FileTranscriber(decoder: ProgressDecoder(cancelled: true),
                                          engine: FakeSpeechEngine(script: []), modelID: "m")
        await #expect(throws: FileTranscriptionError.cancelled) {
            _ = try await transcriber.transcribe(url, options: TranscriptionOptions(language: "en")) { _ in }
        }
    }

    @Test("Stop during a decode chunk cancels the queue before the next chunk")
    func queueStopDuringDecode() async throws {
        let decoder = PausedDecoder()
        let engine = FakeSpeechEngine(script: [])
        try await engine.load(modelAt: URL(fileURLWithPath: "/dev/null"))
        let queue = FileQueue(transcriber: FileTranscriber(decoder: decoder, engine: engine, modelID: "m"),
                              durations: FakeAudioDuration(), supportedExtensions: ["wav"],
                              options: { TranscriptionOptions(language: "en") })
        await queue.add([url])
        let events = await queue.subscribe()
        await queue.start()
        var cancelledAt: ContinuousClock.Instant?
        for await event in events {
            if case .changed(let item) = event, case .running(let progress) = item.status,
               progress > 0 && progress < 0.05 {
                cancelledAt = .now
                await queue.cancel(id: item.id)
                decoder.release.signal()
            }
            if case .idle = event { break }
        }
        #expect(await queue.items.first?.status == .cancelled)
        let start = try #require(cancelledAt)
        #expect(start.duration(to: .now) < .seconds(1))
        await queue.waitUntilIdle()
    }

    private struct ProgressDecoder: AudioDecoding {
        var cancelled = false
        func decode(_ url: URL) throws -> AudioSamples { AudioSamples([0]) }
        func decode(_ url: URL, progress: @Sendable (Double) -> Void) throws -> AudioSamples {
            if cancelled { throw CancellationError() }
            [0.0, 0.25, 0.5, 0.75, 1.0].forEach(progress)
            return AudioSamples([0])
        }
    }

    private final class PausedDecoder: AudioDecoding, Sendable {
        let release = DispatchSemaphore(value: 0)
        func decode(_ url: URL) throws -> AudioSamples { AudioSamples([0]) }
        func decode(_ url: URL, progress: @Sendable (Double) -> Void) throws -> AudioSamples {
            progress(0.5)
            // A bounded stand-in for a synchronous native read. The test cancels the queue and
            // releases this chunk causally; timeout fails instead of hanging on a missed event.
            guard release.wait(timeout: .now() + 2) == .success else {
                throw AudioDecodingError.decodeFailed("test decode chunk was not released")
            }
            try Task.checkCancellation()
            return AudioSamples([0])
        }
    }
}
