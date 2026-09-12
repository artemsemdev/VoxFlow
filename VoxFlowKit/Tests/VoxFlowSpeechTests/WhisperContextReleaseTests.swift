import Foundation
import Synchronization
import Testing
@testable import VoxFlowSpeech

@Suite("Whisper native context release", .timeLimit(.minutes(1)))
struct WhisperContextReleaseTests {
    @Test("release drains earlier file and dictation uses before freeing exactly once")
    func drainsBothPriorities() async {
        let queue = WhisperWorkQueue()
        let events = Mutex<[String]>([])
        let gate = DispatchSemaphore(value: 0)
        queue.enqueue(priority: .dictation) { gate.wait() }
        queue.enqueue(priority: .file) { events.withLock { $0.append("file") } }
        queue.enqueue(priority: .dictation) { events.withLock { $0.append("dictation") } }
        let context = WhisperCppEngine.ContextBox(OpaquePointer(bitPattern: 1)!, queue: queue) { _ in
            events.withLock { $0.append("free") }
        }
        let releasing = Task { await context.release() }
        while queue.pendingCount < 3 { await Task.yield() }
        releasing.cancel() // Cleanup remains mandatory even if its caller is cancelled.
        gate.signal()
        await releasing.value
        #expect(events.withLock { $0 } == ["dictation", "file", "free"])
        await context.release()
        #expect(events.withLock { $0.filter { $0 == "free" }.count } == 1)
    }

    @Test("last-reference cleanup frees on the native queue after pending work")
    func deinitUsesNativeQueue() async throws {
        let queue = WhisperWorkQueue()
        let events = Mutex<[String]>([])
        let gate = DispatchSemaphore(value: 0)
        queue.enqueue(priority: .dictation) { gate.wait() }
        queue.enqueue(priority: .file) { events.withLock { $0.append("file") } }
        do {
            let context = WhisperCppEngine.ContextBox(OpaquePointer(bitPattern: 1)!, queue: queue) { _ in
                events.withLock { $0.append("free") }
            }
            withExtendedLifetime(context) {}
        }
        gate.signal()
        _ = try await queue.run(priority: .file) { 0 }
        #expect(events.withLock { $0 } == ["file", "free"])
    }
}
