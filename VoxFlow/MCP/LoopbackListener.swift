import Foundation
import Network
import Synchronization
import VoxFlowMCP

/// What the transport hands a fully-parsed, peer-identified request to. The concrete
/// implementation (Task 4) composes `MCPHTTPPolicy` + `MCPRouter` + the tool implementations; this
/// task only defines the seam.
protocol MCPRequestHandling: Sendable {
    func handle(_ request: MCPHTTPRequest, peer: MCPPeer) async -> (status: Int, body: Data?)
}

/// Injectable listener operations; lifecycle tests never construct an NWListener or open a socket.
struct MCPListenerCandidate: Sendable {
    let waitUntilReady: @Sendable () async -> Bool
    let cancel: @Sendable () -> Void
}

/// Transport-level failures — distinct from `MCPError` (the JSON-RPC/HTTP-policy error table),
/// which never sees a listener that couldn't bind at all.
enum MCPServerError: Error, Equatable, Sendable {
    case noFreePort

    var message: String {
        switch self {
        case .noFreePort: return "VoxFlow couldn't find a free port for the MCP server (7331–7340 are all in use)."
        }
    }
}

/// Every transport queue and connection lives here, never on `.main` (Task 2 review, I3): the Flow
/// Bar drives the main thread and HTTP framing must not share it.
private let mcpTransportQueue = DispatchQueue(label: "dev.artemsem.voxflow.mcp", qos: .userInitiated)

/// Loopback-only HTTP listener (spike notes §3): `NWParameters.tcp` + `requiredInterfaceType =
/// .loopback` + `NWListener(using:on:)` — *not* `requiredLocalEndpoint`, which silently binds
/// nothing while still reporting `.ready`. Belt-and-braces on top of the interface restriction:
/// `accept(_:)` also drops any connection whose peer `endpoint` host isn't loopback, since `lsof`
/// shows the listener bound on all interfaces even though only loopback peers can complete a
/// connection to it.
///
/// The actor owns the published and pending candidates and every accepted connection. An
/// invalidated startup attempt cannot publish a listener or accept a delayed connection.
actor LoopbackListener {
    /// Task 2 review, I2: beyond this many live connections, a new one is cancelled immediately,
    /// before any byte is read.
    static let maxConcurrentConnections = 16

    private let portRange: ClosedRange<UInt16>
    private let resolver: any PeerResolving
    private let handler: any MCPRequestHandling
    private let framingDeadline: TimeInterval
    private var listener: MCPListenerCandidate?
    private var pendingCandidate: MCPListenerCandidate?
    private let makeCandidate: @Sendable (UInt16, @escaping @Sendable (NWConnection) -> Void) throws -> MCPListenerCandidate
    private let onStartJoined: @Sendable () -> Void
    private var connections: [UUID: ConnectionHandler] = [:]

    /// Task 2 re-review round 2, N1: `start()` suspends (it awaits each candidate's `.ready`/
    /// `.failed`), so without this the actor's isolation alone does **not** make it idempotent or
    /// reentrancy-safe — two concurrent calls, two sequential calls, or a `stop()` racing an
    /// in-flight call could each bind a second port and overwrite `listener` without cancelling the
    /// first, leaving an orphaned, still-serving `NWListener` that `stop()` can never reach (it only
    /// ever knows about `listener`). `inFlightStart` is how a second caller (concurrent or
    /// sequential-while-starting) joins the *same* attempt instead of beginning another;
    /// `generation` is how `stop()` invalidates an attempt that's already suspended awaiting
    /// readiness, so it discards whatever it eventually binds instead of publishing it.
    private var inFlightStart: Task<Void, Error>?
    private var generation = 0

    private(set) var boundPort: UInt16?

    /// How long a candidate listener gets to report `.ready` or `.failed` before it is written off
    /// (final review F6).
    private static let readinessTimeout: TimeInterval = 5

    /// `framingDeadline` is injectable only so a test can drive it without waiting the real 30 s
    /// (final review F2 shipped uncovered; two of the three prior regressions on this file were in
    /// this timer's arming and disarming). Production always uses the default.
    init(portRange: ClosedRange<UInt16> = 7331...7340, resolver: any PeerResolving, handler: any MCPRequestHandling,
         framingDeadline: TimeInterval = ConnectionHandler.defaultFramingDeadline,
         makeCandidate: @escaping @Sendable (UInt16, @escaping @Sendable (NWConnection) -> Void) throws -> MCPListenerCandidate = LoopbackListener.makeNetworkCandidate,
         onStartJoined: @escaping @Sendable () -> Void = {}) {
        self.portRange = portRange
        self.resolver = resolver
        self.handler = handler
        self.framingDeadline = framingDeadline
        self.makeCandidate = makeCandidate
        self.onStartJoined = onStartJoined
    }

    /// Idempotent and reentrancy-safe (see the property doc above): a no-op if already bound;
    /// joins the existing attempt if one is already in flight; otherwise starts exactly one scan.
    /// Tries each port in `portRange` in order, actually waiting for each candidate to reach
    /// `.ready` (bound) or `.failed` (busy) before deciding — Task 2 review, I1:
    /// `NWListener(using:on:)` does **not** throw on a busy port; the bind failure is delivered
    /// asynchronously via `stateUpdateHandler` (`EADDRINUSE`), so `try?` around the initializer
    /// alone always "succeeds" and the fallback range is never reached. `boundPort` is published
    /// only for a listener that has actually reached `.ready`.
    func start() async throws {
        if listener != nil { return } // already running.
        let myGeneration = generation
        if let joined = inFlightStart {
            onStartJoined() // Signals entry before suspension for deterministic lifecycle tests.
            try await joined.value
            guard generation == myGeneration, listener != nil else { throw CancellationError() }
            return // An old caller must never create a new attempt after stop().
        }

        let task = Task { try await self.performScan(generation: myGeneration) }
        inFlightStart = task
        defer { if generation == myGeneration { inFlightStart = nil } }
        try await task.value
        guard generation == myGeneration, listener != nil else { throw CancellationError() }
    }

    /// The actual port scan, run by exactly one `Task` per attempt (see `start()`). `myGeneration`
    /// is captured at the moment the attempt began; if `stop()` runs while this is suspended inside
    /// `waitUntilReady`, it bumps `generation`, and the mismatch here tells this attempt to cancel
    /// whatever it just bound and fail every joined caller with cancellation rather than re-publish
    /// a listener the caller already asked to shut down.
    private func performScan(generation myGeneration: Int) async throws {
        for candidate in portRange {
            guard generation == myGeneration, !Task.isCancelled else { throw CancellationError() }
            guard let newListener = try? makeCandidate(candidate, { [weak self] connection in
                guard let self else { connection.cancel(); return }
                Task { await self.accept(connection, generation: myGeneration) }
            }) else { continue }
            pendingCandidate = newListener
            let ready = await newListener.waitUntilReady()
            guard generation == myGeneration else { throw CancellationError() }
            pendingCandidate = nil
            guard ready else {
                newListener.cancel()
                continue
            }
            listener = newListener
            boundPort = candidate
            return
        }
        guard generation == myGeneration else { throw CancellationError() }
        throw MCPServerError.noFreePort
    }

    private nonisolated static func makeNetworkCandidate(
        port: UInt16, onConnection: @escaping @Sendable (NWConnection) -> Void
    ) throws -> MCPListenerCandidate {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw MCPServerError.noFreePort }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let candidate = try NWListener(using: parameters, on: port)
        candidate.newConnectionHandler = onConnection
        return MCPListenerCandidate(waitUntilReady: { await Self.waitUntilReady(candidate) },
                                    cancel: { candidate.cancel() })
    }

    /// Starts `candidate` and suspends until it reports `.ready` (returns `true`) or `.failed`
    /// (returns `false`; measured on this SDK as `POSIXErrorCode.EADDRINUSE` for a busy port). Resumes at most once, guarded by a `Mutex`, since `stateUpdateHandler` can fire more
    /// than the two states we care about.
    private static func waitUntilReady(_ candidate: NWListener) async -> Bool {
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await startAndAwaitState(candidate)
        } onCancel: { candidate.cancel() }
    }

    private static func startAndAwaitState(_ candidate: NWListener) async -> Bool {
        await withCheckedContinuation { continuation in
            let resumed = Mutex(false)
            /// Final review F6: `.ready`/`.failed` are not the only outcomes. A listener parked in
            /// `.waiting` used to suspend `start()` forever — and because the attempt stays
            /// registered, every later `start()` joined the same stuck attempt, so the server could
            /// never be switched on again for the rest of the session. Treat "neither answer within
            /// the deadline" as a failed candidate and move on.
            // Not cancelled when a state arrives: `DispatchWorkItem` isn't `Sendable`, so it can't be
            // captured by the `@Sendable` state handler below. `resumed` already makes whichever of
            // {state, deadline} lands second a no-op, so a stale firing costs one empty closure.
            let deadline = DispatchWorkItem {
                let shouldResume = resumed.withLock { alreadyResumed -> Bool in
                    guard !alreadyResumed else { return false }
                    alreadyResumed = true
                    return true
                }
                guard shouldResume else { return }
                continuation.resume(returning: false)
            }
            mcpTransportQueue.asyncAfter(deadline: .now() + Self.readinessTimeout, execute: deadline)
            candidate.stateUpdateHandler = { state in
                let outcome: Bool? = resumed.withLock { alreadyResumed in
                    guard !alreadyResumed else { return nil }
                    switch state {
                    case .ready: alreadyResumed = true; return true
                    case .failed, .cancelled: alreadyResumed = true; return false
                    default: return nil
                    }
                }
                guard let outcome else { return }
                continuation.resume(returning: outcome)
            }
            candidate.start(queue: mcpTransportQueue)
        }
    }

    /// Cancels the listener and every live connection (Task 2 review, I2: `stop()` used to cancel
    /// only the listener, so already-accepted connections kept reading and `respond` kept
    /// answering them after the user turned the server off in Settings). Also bumps `generation`
    /// (Task 2 re-review round 2, N1), so an in-flight `start()` — suspended inside
    /// `waitUntilReady`, unaware `stop()` has run — discards whatever it binds afterward instead of
    /// re-publishing a listener the caller just asked to shut down. Safe to call more than once:
    /// `listener?.cancel()` on `nil` and an empty `connections` loop are both no-ops.
    func stop() {
        generation += 1
        // Forget the old attempt before a new start can enter; cancel the pending candidate now,
        // without waiting for readiness or its timeout. Old completion cannot clear newer state.
        inFlightStart?.cancel()
        inFlightStart = nil
        pendingCandidate?.cancel()
        pendingCandidate = nil
        listener?.cancel()
        listener = nil
        boundPort = nil
        for (_, handler) in connections { handler.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection, generation acceptedGeneration: Int) {
        guard generation == acceptedGeneration else { connection.cancel(); return }
        // `connection.endpoint` is the remote peer for a connection handed to a listener's
        // `newConnectionHandler` — NWConnection has no separate `remoteEndpoint`; that name
        // belongs to `NWConnectionGroup.Message`/`NWPath`, not this type.
        guard isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        guard connections.count < Self.maxConcurrentConnections else {
            connection.cancel()
            return
        }
        guard let boundPort else {
            connection.cancel()
            return
        }

        // Final review F1: resolution is *deferred*, not done here. Walking every process's file
        // descriptors costs ~5 ms and ~14,000 syscalls, and doing it on accept meant any local
        // process could spend the listener's queue with a `connect()` loop before a single token
        // was checked. `MCPPeer` resolves once, on demand, from inside the authenticated path.
        // An empty name still signals "resolution failed entirely"; substituting display copy like
        // "Unknown app" belongs to the runner, not the transport.
        let peerPort = remotePort(of: connection)
        let resolver = resolver
        let peer = MCPPeer { @Sendable in
            guard let peerPort, let resolved = resolver.resolveProcess(peerPort: peerPort, serverPort: boundPort) else {
                return MCPClientIdentity(name: "", path: "", pid: nil)
            }
            return MCPClientIdentity(name: resolved.name, path: resolved.path, pid: resolved.pid)
        }

        let id = UUID()
        let connectionHandler = ConnectionHandler(
            connection: connection, queue: mcpTransportQueue, peer: peer, handler: handler, framingDeadline: framingDeadline,
            onFinish: { [weak self] in Task { await self?.remove(id) } }
        )
        connections[id] = connectionHandler
        connectionHandler.start()
    }

    private func remove(_ id: UUID) {
        connections.removeValue(forKey: id)
    }

    private func remotePort(of connection: NWConnection) -> UInt16? {
        guard case .hostPort(_, let port) = connection.endpoint else { return nil }
        return port.rawValue
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        case .name: return false
        @unknown default: return false
        }
    }
}

/// One accepted connection: reads until a full HTTP request is framed, hands it to the handler,
/// writes the response, and closes. `final class … : Sendable` with a `Mutex`-boxed `HTTPFraming`
/// value (spike gotcha 3) — a recursive local `func receive()` captured by `NWConnection.receive`'s
/// `@Sendable` completion doesn't compile under Swift 6 ("concurrently-executed local function must
/// be marked `@Sendable`" plus a non-Sendable capture), so `receive()` is a method instead.
///
/// Task 2 review, C1/I2: bounds and lifecycle a single unauthenticated local process could otherwise
/// abuse before any token check ever runs — `HTTPFraming`'s 16 KB header cap and 1 MB whole-request
/// cap, a 30 s idle deadline, and a last-resort connection watchdog, all funneled through one
/// `finish()` so `onFinish` (which lets `LoopbackListener` drop this connection from its registry)
/// fires exactly once no matter which path ends the connection.
final class ConnectionHandler: Sendable {
    /// How long an accepted connection may take to deliver a complete request. Final review F2:
    /// this used to be refreshed on every chunk, so a peer dripping one byte at a time held its
    /// slot forever — and with the connection cap at 16, sixteen such peers locked every real
    /// client out, all before any token was checked. It is now an **absolute** deadline armed once
    /// when the connection becomes ready and disarmed only when a request has been framed; the
    /// 20-minute watchdog below takes over from there.
    static let defaultFramingDeadline: TimeInterval = 30
    /// Task 3 review / plan amendment (aefea6e): **not** a per-tool timeout — the transport doesn't
    /// know which tool a request names, and shouldn't learn. Each tool owns its own budget
    /// (`dictate` runs up to ~920 s; `transcribe_file` on a long recording takes minutes), so 30 s
    /// here would have returned nothing to the client while the real work continued, and made the
    /// tools' own timeout paths unreachable. This exists only as a last-resort guard against a
    /// connection pinned open forever by a handler that never returns at all.
    private static let connectionWatchdog: TimeInterval = 20 * 60

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let peer: MCPPeer
    private let handler: any MCPRequestHandling
    private let framingDeadline: TimeInterval
    private let onFinish: @Sendable () -> Void

    /// Task 2 re-review round 2, N2/N3: the request-framing state machine (size caps, terminator
    /// search offset, and — the point of N2 — a header decoded exactly once) lives in the pure,
    /// unit-tested `HTTPFraming`, not inline here; this `Mutex` is only about giving concurrent
    /// `NWConnection.receive` completions exclusive access to the one `HTTPFraming` value.
    private let framing = Mutex(HTTPFraming())
    private let idleWork = Mutex<DispatchWorkItem?>(nil)
    private let finished = Mutex(false)

    init(connection: NWConnection, queue: DispatchQueue, peer: MCPPeer, handler: any MCPRequestHandling,
         framingDeadline: TimeInterval = ConnectionHandler.defaultFramingDeadline, onFinish: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.queue = queue
        self.peer = peer
        self.handler = handler
        self.framingDeadline = framingDeadline
        self.onFinish = onFinish
    }

    /// Cancels the connection from the outside (e.g. `LoopbackListener.stop()`). `finish()` itself
    /// runs once the resulting `.cancelled` state arrives.
    func cancel() {
        connection.cancel()
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                armFramingDeadline()
                receive()
            case .failed, .waiting:
                // Task 2 review, I2: unhandled before, these connections leaked — held alive by the
                // `[self]` cycle with no timeout and no cancellation. `.waiting` is treated the same
                // as `.failed` rather than given a chance to recover: on a loopback-only listener a
                // connection that isn't immediately ready has nothing to wait for.
                connection.cancel()
            case .cancelled:
                finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] chunk, _, isComplete, error in
            let step = framing.withLock { $0.advance(appending: chunk ?? Data()) }

            switch step {
            case .tooLarge:
                closeWithStatus(413)
            case .complete(let request):
                respond(to: request)
            case .needMore:
                guard error == nil, !isComplete else {
                    connection.cancel()
                    return
                }
                receive()
            }
        }
    }

    /// `handler.handle` runs in an unstructured `Task` that this method does not itself await —
    /// deliberately: a `withTaskGroup`-based race would still block this connection's teardown on
    /// the slow task's eventual completion (structured concurrency awaits every child before the
    /// group returns, cancellation or not), which is exactly the "pinned forever" failure mode the
    /// watchdog exists to prevent. Instead, a queue timer independently cancels the *connection*
    /// after `connectionWatchdog`; a `Mutex`-guarded flag makes whichever of {timer, handler} arrives
    /// second a no-op, so a slow handler that eventually does return can never send a response onto
    /// a connection this already closed.
    private func respond(to request: MCPHTTPRequest) {
        // Re-review finding 4: the framing deadline exists to close a connection that never
        // delivers a whole request. One is framed now, so it must be disarmed here — otherwise it
        // fires and cancels the connection out from under a tool that is legitimately still working
        // (`dictate` runs up to ~920 s), which made the 20-minute watchdog below unreachable and
        // returned nothing to the client.
        idleWork.withLock { $0?.cancel(); $0 = nil }
        let responded = Mutex(false)

        let timeoutWork = DispatchWorkItem { [connection] in
            let shouldTimeOut = responded.withLock { done -> Bool in
                guard !done else { return false }
                done = true
                return true
            }
            guard shouldTimeOut else { return }
            connection.cancel() // the handler hung; don't pin the connection open waiting for it.
        }
        queue.asyncAfter(deadline: .now() + Self.connectionWatchdog, execute: timeoutWork)

        Task {
            let (status, body) = await handler.handle(request, peer: peer)
            let shouldSend = responded.withLock { done -> Bool in
                guard !done else { return false }
                done = true
                return true
            }
            timeoutWork.cancel()
            guard shouldSend else { return } // already timed out; the connection is already closing.
            send(status: status, body: body)
        }
    }

    private func closeWithStatus(_ status: Int) {
        send(status: status, body: nil)
    }

    private func send(status: Int, body: Data?) {
        let response = HTTPMessage.write(status: status, body: body)
        connection.send(content: response, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    /// Cancels the framing deadline and detaches `stateUpdateHandler`, so `finish()` (reached only via
    /// `.cancelled`) never fires twice, and calls `onFinish` exactly once. Clearing
    /// `stateUpdateHandler` here matters beyond tidiness: it holds a `[self]` capture (the spike's
    /// recipe — required so a recursive `receive()` compiles, see the type doc), which together
    /// with this instance's own `let connection: NWConnection` is a genuine reference cycle that
    /// ARC cannot break on its own. Nothing else needs the handler once the connection is
    /// `.cancelled`, so detaching it here is what actually lets both objects deallocate.
    private func finish() {
        let alreadyFinished = finished.withLock { done -> Bool in
            let was = done
            done = true
            return was
        }
        guard !alreadyFinished else { return }
        idleWork.withLock { $0?.cancel(); $0 = nil }
        connection.stateUpdateHandler = nil
        onFinish()
    }

    /// The new `DispatchWorkItem` is created *and* scheduled inside the `withLock` closure, rather
    /// than built outside and assigned in: `Mutex`'s `withLock` takes its closure's stored value as
    /// `inout sending`, and a value created outside the closure that is also used after it returns
    /// (as `queue.asyncAfter` below would have been) still carries a live reference in this
    /// function's region, which the compiler rejects as not fully "sent". Building and scheduling
    /// it in one place sidesteps that — nothing about `work` survives past the closure.
    /// Armed once, when the connection becomes ready — never refreshed (final review F2).
    private func armFramingDeadline() {
        idleWork.withLock { previous in
            previous?.cancel()
            let work = DispatchWorkItem { [connection] in connection.cancel() }
            previous = work
            queue.asyncAfter(deadline: .now() + framingDeadline, execute: work)
        }
    }
}
