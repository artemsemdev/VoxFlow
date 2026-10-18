import Foundation
import Synchronization
import Testing
@testable import VoxFlowSpeech

@Suite("WhisperWorkQueue", .timeLimit(.minutes(1)))
struct WhisperWorkQueueTests {
    @Test("pending dictation precedes queued file work, with FIFO ordering within each role")
    func prioritizesDictation() async {
        let queue = WhisperWorkQueue()
        let (events, continuation) = AsyncStream<String>.makeStream()
        let releaseFile = DispatchSemaphore(value: 0)
        queue.enqueue(priority: .file) {
            continuation.yield("file started")
            releaseFile.wait() // Runs on the native-work dispatch queue, never on a cooperative thread.
            continuation.yield("file finished")
        }
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == "file started")
        queue.enqueue(priority: .file) { continuation.yield("file 2") }
        queue.enqueue(priority: .dictation) { continuation.yield("dictation 1") }
        queue.enqueue(priority: .file) { continuation.yield("file 3") }
        queue.enqueue(priority: .dictation) { continuation.yield("dictation 2") }
        releaseFile.signal()
        var result: [String] = []
        for _ in 0..<5 { if let event = await iterator.next() { result.append(event) } }
        #expect(result == ["file finished", "dictation 1", "dictation 2", "file 2", "file 3"])
        continuation.finish()
    }

    @Test("concurrent submissions never overlap native operations and the queue restarts after draining")
    func serializes() async throws {
        let queue = WhisperWorkQueue()
        let active = ActiveWork()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    try await queue.run(priority: index.isMultiple(of: 2) ? .dictation : .file) {
                        active.enter()
                        active.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(try await queue.run(priority: .file) { 42 } == 42)
    }

    @Test("an already cancelled operation never reaches native work; failure does not stall the next job")
    func cancellationAndFailure() async throws {
        let queue = WhisperWorkQueue()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await queue.run(priority: .file) { 42 }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        enum Failure: Error { case native }
        await #expect(throws: Failure.native) {
            try await queue.run(priority: .file) { throw Failure.native }
        }
        #expect(try await queue.run(priority: .dictation) { 7 } == 7)
    }

    @Test("cancellation while queued skips native work without stalling later requests")
    func queuedCancellation() async throws {
        let queue = WhisperWorkQueue()
        let release = DispatchSemaphore(value: 0)
        queue.enqueue(priority: .file) { release.wait() }
        let task = Task { try await queue.run(priority: .dictation) { 42 } }
        while queue.pendingCount == 0 { await Task.yield() }
        task.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await queue.run(priority: .file) { 7 } == 7)
    }

    private final class ActiveWork: Sendable {
        private let count = Mutex(0)
        func enter() { count.withLock { $0 += 1; #expect($0 == 1) } }
        func leave() { count.withLock { $0 -= 1 } }
    }
}
