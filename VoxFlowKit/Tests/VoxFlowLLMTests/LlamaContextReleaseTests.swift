import Foundation
import Synchronization
import Testing
import VoxFlowTestSupport
@testable import VoxFlowLLM

@Suite("Llama native release", .timeLimit(.minutes(1)))
struct LlamaContextReleaseTests {
    @Test("release drains native work, waits for both frees and ignores caller cancellation")
    func drainsAndWaits() async {
        let queue = DispatchQueue(label: "test.llama.release")
        let events = Mutex<[String]>([])
        let entered = Gate()
        let finish = DispatchSemaphore(value: 0)
        queue.async { events.withLock { $0.append("work") } }
        let context = LlamaEngine.ContextBox(OpaquePointer(bitPattern: 1)!, model: OpaquePointer(bitPattern: 2)!, queue: queue) { _, _ in
            events.withLock { $0.append("context") }
            Task { await entered.open() }
            finish.wait()
            events.withLock { $0.append("model") }
        }
        let release = Task { await context.release(); events.withLock { $0.append("returned") } }
        await entered.wait()
        #expect(events.withLock { $0 } == ["work", "context"])
        release.cancel()
        finish.signal()
        await release.value
        await context.release()
        #expect(events.withLock { $0 } == ["work", "context", "model", "returned"])
    }

    @Test("last-reference fallback releases the pair exactly once on its native queue")
    func deinitFallback() async {
        let queue = DispatchQueue(label: "test.llama.deinit")
        let events = Mutex<[String]>([])
        queue.async { events.withLock { $0.append("work") } }
        do {
            let context = LlamaEngine.ContextBox(OpaquePointer(bitPattern: 1)!, model: OpaquePointer(bitPattern: 2)!, queue: queue) { _, _ in
                dispatchPrecondition(condition: .onQueue(queue))
                events.withLock { $0.append("context+model") }
            }
            withExtendedLifetime(context) {}
        }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        #expect(events.withLock { $0 } == ["work", "context+model"])
    }
}
