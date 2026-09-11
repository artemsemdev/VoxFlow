import Synchronization
import Testing
import VoxFlowTestSupport
@testable import VoxFlow

@Suite("Dictation command queue", .timeLimit(.minutes(1)))
@MainActor
struct DictationCommandQueueTests {
    @Test("a release waits for preparation; repeated start never adds a second consumer")
    func preservesOrder() async {
        let queue = DictationCommandQueue(), entered = Gate(), release = Gate(), done = Gate(), events = Events()
        queue.send(preparation: true) {
            events.append("down entered")
            await entered.open()
            await release.wait()
            events.append("down finished")
        }
        queue.send { events.append("up"); await done.open() }
        queue.start()
        await entered.wait()
        queue.start()
        #expect(events.values == ["down entered"])
        await release.open()
        await done.wait()
        #expect(events.values == ["down entered", "down finished", "up"])
    }

    @Test("Escape invalidates preparations queued before the consumer starts, retaining later commands")
    func cancelsQueued() async {
        let queue = DictationCommandQueue(), done = Gate(), events = Events()
        queue.send(preparation: true) { events.append("stale start") }
        queue.send(preparation: true) { events.append("stale paste") }
        queue.cancelPreparations()
        queue.send { events.append("escape") }
        queue.send(preparation: true) { events.append("new start") }
        queue.send { await done.open() }
        queue.start()
        await done.wait()
        #expect(events.values == ["escape", "new start"])
    }

    @Test("Escape cancels the task awaiting preparation, so it cannot paste after resuming")
    func cancelsSuspended() async {
        let queue = DictationCommandQueue(), entered = Gate(), release = Gate(), done = Gate(), events = Events()
        queue.send(preparation: true) {
            await entered.open()
            await release.wait()
            events.append(Task.isCancelled ? "cancelled" : "paste")
        }
        queue.send(preparation: true) { events.append("stale second start") }
        queue.start()
        await entered.wait()
        queue.cancelPreparations()
        queue.send { events.append("escape"); await done.open() }
        await release.open()
        await done.wait()
        #expect(events.values == ["cancelled", "escape"])
    }

    @Test("releasing the queue cancels suspended preparation without retaining its owner")
    func lifetime() async {
        let entered = Gate(), release = Gate(), done = Gate(), events = Events()
        var queue: DictationCommandQueue? = DictationCommandQueue()
        weak var weakQueue: DictationCommandQueue?
        weakQueue = queue
        queue?.send(preparation: true) {
            await entered.open()
            await release.wait()
            events.append(Task.isCancelled ? "cancelled" : "paste")
            await done.open()
        }
        queue?.start()
        await entered.wait()
        queue = nil
        #expect(weakQueue == nil)
        await release.open()
        await done.wait()
        #expect(events.values == ["cancelled"])
    }

    final class Events: Sendable {
        private let storage = Mutex<[String]>([])
        func append(_ value: String) { storage.withLock { $0.append(value) } }
        var values: [String] { storage.withLock { $0 } }
    }
}
