import Foundation
import Testing
import VoxFlowCore
@testable import VoxFlowAudio

@Suite("MicrophoneSource (RequiresMicrophone)",
       .enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_MIC_TESTS"] == "1", "Set VOXFLOW_MIC_TESTS=1 to capture from the default input"),
       .timeLimit(.minutes(1)))
struct MicrophoneSourceIntegrationTests {
    @Test("three selected-input captures dispose promptly, without callback timeouts")
    func selectedInputRepeats() async throws {
        let uid = try #require(ProcessInfo.processInfo.environment["VOXFLOW_MIC_DEVICE_UID"]
                               ?? AudioInputDevices.defaultDevice()?.id)
        for _ in 0..<3 {
            let audio = AsyncThrowingStream<MicrophoneEvent, Error>.makeStream()
            let stopped = AsyncStream<Void>.makeStream()
            let session = SelectedMicrophoneSession(uid: uid, chunkSeconds: 0.1,
                classifyError: { .engineFailed($0) }, continuation: audio.continuation,
                onStopped: { stopped.continuation.yield(()); stopped.continuation.finish() })
            audio.continuation.onTermination = { _ in session.stop() }
            session.start()
            var iterator = audio.stream.makeAsyncIterator()
            let event = try #require(try await iterator.next())
            guard case .chunk(let chunk) = event else { Issue.record("Expected microphone audio"); return }
            #expect(chunk.samples.count == 1600)
            let clock = ContinuousClock()
            let start = clock.now
            audio.continuation.finish()
            var completion = stopped.stream.makeAsyncIterator()
            _ = await completion.next()
            let elapsed = clock.now - start
            #expect(elapsed < .seconds(2), "Selected-input shutdown took \(elapsed)")
        }
    }

    @Test("delivers 100 ms chunks at 16 kHz and stops when the consumer cancels")
    func captures() async throws {
        let source = MicrophoneSource()
        var received: [AudioChunk] = []
        let task = Task {
            var chunks: [AudioChunk] = []
            for try await event in source.start() {
                if case .chunk(let c) = event { chunks.append(c) }
                if chunks.count == 5 { break }
            }
            return chunks
        }
        received = try await task.value
        #expect(received.count == 5)
        #expect(received.allSatisfy { $0.samples.count == 1600 })
    }
}
