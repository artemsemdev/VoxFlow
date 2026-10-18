import Foundation
import Testing
import VoxFlowCore
@testable import VoxFlowAudio

@Suite("MicrophoneSource (RequiresMicrophone)",
       .enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_MIC_TESTS"] == "1", "Set VOXFLOW_MIC_TESTS=1 to capture from the default input"),
       .timeLimit(.minutes(1)))
struct MicrophoneSourceIntegrationTests {
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
