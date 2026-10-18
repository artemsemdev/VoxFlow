import Foundation
import Synchronization
import Testing
import VoxFlowMCP
@testable import VoxFlow

private final class ListenerProbe: Sendable {
    private struct State {
        var outcome: Bool?
        var waiter: CheckedContinuation<Bool, Never>?
        var cancellations = 0
    }
    private let state: Mutex<State>
    let entered = AsyncStream<Void>.makeStream()

    init(ready: Bool? = nil) { state = Mutex(State(outcome: ready)) }
    var cancellations: Int { state.withLock { $0.cancellations } }
    var candidate: MCPListenerCandidate {
        MCPListenerCandidate(waitUntilReady: { await self.wait() }, cancel: {
            self.state.withLock { $0.cancellations += 1 }
        })
    }
    private func wait() async -> Bool {
        entered.continuation.yield()
        return await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool? in
                if let outcome = state.outcome { return outcome }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
    func release(_ ready: Bool) {
        let waiter = state.withLock { state in
            state.outcome = ready
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: ready)
    }
    func waitForEntry() async { for await _ in entered.stream { return } }
}

private final class ListenerFactoryProbe: Sendable {
    enum Entry: Sendable { case candidate, joined }
    let entries = AsyncStream<Entry>.makeStream()
    private let calls = Mutex<[UInt16]>([])
    private let candidates: [ListenerProbe?]
    init(_ candidates: [ListenerProbe?]) { self.candidates = candidates }
    var ports: [UInt16] { calls.withLock { $0 } }
    func make(port: UInt16) throws -> MCPListenerCandidate {
        let index = calls.withLock { ports in
            defer { ports.append(port) }
            return ports.count
        }
        entries.continuation.yield(.candidate)
        // Unexpected scans finish immediately so the regression fails rather than hanging.
        guard index < candidates.count else { return ListenerProbe(ready: true).candidate }
        guard let candidate = candidates[index] else { throw MCPServerError.noFreePort }
        return candidate.candidate
    }
    func listener() -> LoopbackListener {
        LoopbackListener(portRange: 7331...7333, resolver: LifecycleResolver(), handler: LifecycleHandler(),
                         makeCandidate: { port, _ in try self.make(port: port) },
                         onStartJoined: { self.entries.continuation.yield(.joined) })
    }
    func finish() {
        for candidate in candidates.compactMap({ $0 }) {
            candidate.release(false)
            candidate.entered.continuation.finish()
        }
        entries.continuation.finish()
    }
}
private struct LifecycleResolver: PeerResolving {
    func resolveProcess(peerPort: UInt16, serverPort: UInt16) -> (pid: Int32, name: String, path: String)? { nil }
}
private struct LifecycleHandler: MCPRequestHandling {
    func handle(_ request: MCPHTTPRequest, peer: MCPPeer) async -> (status: Int, body: Data?) { (200, nil) }
}

@Suite("LoopbackListener lifecycle without sockets", .timeLimit(.minutes(1)))
struct LoopbackListenerLifecycleTests {
    @Test("stop invalidates the starter and every joined caller without a new scan")
    func stoppedJoinersCannotRestart() async {
        let candidate = ListenerProbe()
        let factory = ListenerFactoryProbe([candidate])
        defer { factory.finish() }
        var entries = factory.entries.stream.makeAsyncIterator()
        let listener = factory.listener()
        let first = Task { try await listener.start() }
        await candidate.waitForEntry()
        #expect(await entries.next() == .candidate)
        let second = Task { try await listener.start() }
        #expect(await entries.next() == .joined)
        let third = Task { try await listener.start() }
        #expect(await entries.next() == .joined)
        await listener.stop()
        #expect(candidate.cancellations == 1)
        candidate.release(true) // Simulate a late ready callback even after cancellation.
        for task in [first, second, third] {
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(factory.ports == [7331])
        #expect(await listener.boundPort == nil)
        await listener.stop()
    }

    @Test("old completions cannot publish over or clear a fresh post-stop attempt")
    func restartSurvivesOldCompletion() async throws {
        let old = ListenerProbe(), fresh = ListenerProbe()
        let factory = ListenerFactoryProbe([old, fresh])
        defer { factory.finish() }
        var entries = factory.entries.stream.makeAsyncIterator()
        let listener = factory.listener()
        let first = Task { try await listener.start() }
        await old.waitForEntry()
        #expect(await entries.next() == .candidate)
        let second = Task { try await listener.start() }
        #expect(await entries.next() == .joined)
        await listener.stop()
        let restart = Task { try await listener.start() }
        await fresh.waitForEntry()
        #expect(await entries.next() == .candidate)
        old.release(true)
        for task in [first, second] {
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(factory.ports == [7331, 7331])
        #expect(await listener.boundPort == nil)
        #expect(fresh.cancellations == 0)
        // The old starter's cleanup must leave the new attempt registered for later joiners.
        let fourth = Task { try await listener.start() }
        #expect(await entries.next() == .joined)
        #expect(factory.ports == [7331, 7331])
        fresh.release(true)
        try await restart.value
        try await fourth.value
        #expect(await listener.boundPort == 7331)
        await listener.stop()
        #expect(fresh.cancellations == 1)
    }

    @Test("concurrent and repeated successful starts share exactly one candidate")
    func sharedSuccess() async throws {
        let candidate = ListenerProbe()
        let factory = ListenerFactoryProbe([candidate])
        defer { factory.finish() }
        var entries = factory.entries.stream.makeAsyncIterator()
        let listener = factory.listener()
        let first = Task { try await listener.start() }
        await candidate.waitForEntry()
        #expect(await entries.next() == .candidate)
        let second = Task { try await listener.start() }
        #expect(await entries.next() == .joined)
        candidate.release(true)
        try await first.value
        try await second.value
        try await listener.start()
        #expect(factory.ports == [7331])
        #expect(await listener.boundPort == 7331)
        await listener.stop()
        #expect(candidate.cancellations == 1)
    }

    @Test("constructor and readiness failures fall through to the next port")
    func fallback() async throws {
        let busy = ListenerProbe(ready: false), free = ListenerProbe(ready: true)
        let factory = ListenerFactoryProbe([nil, busy, free])
        defer { factory.finish() }
        let listener = factory.listener()
        try await listener.start()
        #expect(factory.ports == [7331, 7332, 7333])
        #expect(busy.cancellations == 1)
        #expect(await listener.boundPort == 7333)
        await listener.stop()
        #expect(free.cancellations == 1)
    }

    @Test("exhausting the range reports noFreePort and cancels failed candidates")
    func exhaustedRange() async {
        let busy = ListenerProbe(ready: false)
        let factory = ListenerFactoryProbe([nil, busy, nil])
        defer { factory.finish() }
        let listener = factory.listener()
        await #expect(throws: MCPServerError.noFreePort) { try await listener.start() }
        #expect(factory.ports == [7331, 7332, 7333])
        #expect(busy.cancellations == 1)
        #expect(await listener.boundPort == nil)
    }
}
