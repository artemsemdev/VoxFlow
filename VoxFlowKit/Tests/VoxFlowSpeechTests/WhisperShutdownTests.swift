import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowSpeech

@Suite("Whisper terminal shutdown", .timeLimit(.minutes(1)))
struct WhisperShutdownTests {
    @Test("shutdown releases the loaded model once and rejects future loads")
    func loadedModel() async throws {
        let events = Mutex<[String]>([])
        let engine = WhisperCppEngine(queue: WhisperWorkQueue()) { _, queue in
            events.withLock { $0.append("load") }
            return WhisperCppEngine.ContextBox(OpaquePointer(bitPattern: 1)!, queue: queue) { _ in
                events.withLock { $0.append("free") }
            }
        }
        try await engine.load(modelAt: URL(fileURLWithPath: "/fixture"))
        await engine.shutdown()
        await engine.shutdown()
        #expect(events.withLock { $0 } == ["load", "free"])
        await #expect(throws: SpeechEngineError.cancelled) {
            try await engine.load(modelAt: URL(fileURLWithPath: "/fixture"))
        }
        #expect(events.withLock { $0 } == ["load", "free"])
    }

    @Test("shutdown waits for a late native load and frees its result instead of installing it")
    func inFlightLoad() async throws {
        let entered = Gate(), release = DispatchSemaphore(value: 0)
        let events = Mutex<[String]>([])
        let engine = WhisperCppEngine(queue: WhisperWorkQueue()) { _, queue in
            Task { await entered.open() }
            release.wait()
            events.withLock { $0.append("loaded") }
            return WhisperCppEngine.ContextBox(OpaquePointer(bitPattern: 1)!, queue: queue) { _ in
                events.withLock { $0.append("freed") }
            }
        }
        let load = Task { try await engine.load(modelAt: URL(fileURLWithPath: "/fixture")) }
        await entered.wait()
        let shutdown = Task { await engine.shutdown(); events.withLock { $0.append("shutdown") } }
        while await !engine.isShuttingDown { await Task.yield() }
        shutdown.cancel() // Caller cancellation must never skip native teardown.
        #expect(events.withLock { $0.isEmpty })
        release.signal()
        await shutdown.value
        await #expect(throws: SpeechEngineError.cancelled) { try await load.value }
        #expect(events.withLock { $0 } == ["loaded", "freed", "shutdown"])
    }

    @Test("shutdown also waits for an unload that has already detached the model")
    func pendingUnload() async throws {
        let entered = Gate(), release = DispatchSemaphore(value: 0)
        let events = Mutex<[String]>([])
        let engine = WhisperCppEngine(queue: WhisperWorkQueue()) { _, queue in
            WhisperCppEngine.ContextBox(OpaquePointer(bitPattern: 1)!, queue: queue) { _ in
                Task { await entered.open() }
                release.wait()
                events.withLock { $0.append("freed") }
            }
        }
        try await engine.load(modelAt: URL(fileURLWithPath: "/fixture"))
        let unload = Task { await engine.unload() }
        await entered.wait()
        let shutdown = Task { await engine.shutdown(); events.withLock { $0.append("shutdown") } }
        while await !engine.isShuttingDown { await Task.yield() }
        #expect(events.withLock { $0.isEmpty })
        release.signal()
        await shutdown.value
        await unload.value
        #expect(events.withLock { $0 } == ["freed", "shutdown"])
    }

    @Test("terminal cleanup follows queued work from both file and dictation clients")
    func queuedWork() async throws {
        let queue = WhisperWorkQueue()
        let events = Mutex<[String]>([])
        let engine = WhisperCppEngine(queue: queue) { _, queue in
            WhisperCppEngine.ContextBox(OpaquePointer(bitPattern: 1)!, queue: queue) { _ in
                events.withLock { $0.append("free") }
            }
        }
        try await engine.load(modelAt: URL(fileURLWithPath: "/fixture"))
        let hold = DispatchSemaphore(value: 0)
        queue.enqueue(priority: .dictation) { hold.wait() }
        queue.enqueue(priority: .file) { events.withLock { $0.append("file") } }
        queue.enqueue(priority: .dictation) { events.withLock { $0.append("dictation") } }
        let shutdown = Task { await engine.shutdown(); events.withLock { $0.append("shutdown") } }
        while await !engine.isShuttingDown { await Task.yield() }
        hold.signal()
        await shutdown.value
        #expect(events.withLock { $0 } == ["dictation", "file", "free", "shutdown"])
    }
}
