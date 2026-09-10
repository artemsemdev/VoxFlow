import Foundation
import Network
import Synchronization
import VoxFlowMCP

/// What the transport hands a fully-parsed, peer-identified request to. The concrete
/// implementation (Task 4) composes `MCPHTTPPolicy` + `MCPRouter` + the tool implementations; this
/// task only defines the seam.
protocol MCPRequestHandling: Sendable {
    func handle(_ request: MCPHTTPRequest, peer: MCPClientIdentity) async -> (status: Int, body: Data?)
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
/// An `actor`, per the brief's signature: `NWListener` needs no `Sendable` conformance to live in
/// `listener` here, because actor-isolated stored properties are only ever touched from this
/// actor's serial executor — Sendable only matters for values that cross an isolation boundary
/// (the `newConnectionHandler` closure below, which is `@Sendable` and captures `self`, not
/// `listener` itself).
actor LoopbackListener {
    /// Task 2 review, I2: beyond this many live connections, a new one is cancelled immediately,
    /// before any byte is read.
    static let maxConcurrentConnections = 16

    private let portRange: ClosedRange<UInt16>
    private let resolver: any PeerResolving
    private let handler: any MCPRequestHandling
    private var listener: NWListener?
    private var connections: [UUID: ConnectionHandler] = [:]

    private(set) var boundPort: UInt16?

    init(portRange: ClosedRange<UInt16> = 7331...7340, resolver: any PeerResolving, handler: any MCPRequestHandling) {
        self.portRange = portRange
        self.resolver = resolver
        self.handler = handler
    }

    /// Tries each port in `portRange` in order, actually waiting for each candidate to reach
    /// `.ready` (bound) or `.failed` (busy) before deciding — Task 2 review, I1:
    /// `NWListener(using:on:)` does **not** throw on a busy port; the bind failure is delivered
    /// asynchronously via `stateUpdateHandler` (`EADDRINUSE`), so `try?` around the initializer
    /// alone always "succeeds" and the fallback range is never reached. `boundPort` is published
    /// only for a listener that has actually reached `.ready`.
    func start() async throws {
        for candidate in portRange {
            guard let port = NWEndpoint.Port(rawValue: candidate) else { continue }
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            guard let newListener = try? NWListener(using: parameters, on: port) else { continue }

            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { await self.accept(connection) }
            }

            guard await Self.waitUntilReady(newListener) else {
                newListener.cancel()
                continue
            }
            listener = newListener
            boundPort = candidate
            return
        }
        throw MCPServerError.noFreePort
    }

    /// Starts `candidate` and suspends until it reports `.ready` (returns `true`) or `.failed`
    /// (returns `true` → `false`; measured on this SDK as `POSIXErrorCode.EADDRINUSE` for a busy
    /// port). Resumes at most once, guarded by a `Mutex`, since `stateUpdateHandler` can fire more
    /// than the two states we care about.
    private static func waitUntilReady(_ candidate: NWListener) async -> Bool {
        await withCheckedContinuation { continuation in
            let resumed = Mutex(false)
            candidate.stateUpdateHandler = { state in
                let outcome: Bool? = resumed.withLock { alreadyResumed in
                    guard !alreadyResumed else { return nil }
                    switch state {
                    case .ready: alreadyResumed = true; return true
                    case .failed: alreadyResumed = true; return false
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
    /// answering them after the user turned the server off in Settings).
    func stop() {
        listener?.cancel()
        listener = nil
        boundPort = nil
        for (_, handler) in connections { handler.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
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

        // Empty name signals "resolution failed entirely" to the caller (per the resolutions
        // note, substituting display copy like "Unknown app" is Task 3's job, not the transport's).
        let identity: MCPClientIdentity
        if let peerPort = remotePort(of: connection),
           let resolved = resolver.resolveProcess(peerPort: peerPort, serverPort: boundPort) {
            identity = MCPClientIdentity(name: resolved.name, path: resolved.path, pid: resolved.pid)
        } else {
            identity = MCPClientIdentity(name: "", path: "", pid: nil)
        }

        let id = UUID()
        let connectionHandler = ConnectionHandler(
            connection: connection, queue: mcpTransportQueue, identity: identity, handler: handler,
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
/// writes the response, and closes. `final class … : Sendable` with a `Mutex`-boxed receive buffer
/// (spike gotcha 3) — a recursive local `func receive()` captured by `NWConnection.receive`'s
/// `@Sendable` completion doesn't compile under Swift 6 ("concurrently-executed local function must
/// be marked `@Sendable`" plus a non-Sendable capture), so `receive()` is a method instead.
///
/// Task 2 review, C1/I2: bounds and lifecycle a single unauthenticated local process could otherwise
/// abuse before any token check ever runs — a 16 KB header cap, a 1 MB whole-request cap, a 30 s idle
/// deadline, and a handler timeout, all funneled through one `finish()` so `onFinish` (which lets
/// `LoopbackListener` drop this connection from its registry) fires exactly once no matter which path
/// ends the connection.
final class ConnectionHandler: Sendable {
    /// Task 2 review, I2: no bytes at all for this long closes the connection.
    private static let idleTimeout: TimeInterval = 30
    /// Task 2 review, I2: a hung `handler.handle` can't pin a connection open forever.
    private static let handlerTimeout: TimeInterval = 30

    /// Everything mutated while framing one request, behind a single lock so the buffer and the
    /// "how far have we already searched for the terminator" offset never drift apart.
    private struct ReceiveState {
        var data = Data()
        var searchFrom = 0
        var headerFound = false
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let identity: MCPClientIdentity
    private let handler: any MCPRequestHandling
    private let onFinish: @Sendable () -> Void

    private let receiveState = Mutex(ReceiveState())
    private let idleWork = Mutex<DispatchWorkItem?>(nil)
    private let finished = Mutex(false)

    init(connection: NWConnection, queue: DispatchQueue, identity: MCPClientIdentity, handler: any MCPRequestHandling, onFinish: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.queue = queue
        self.identity = identity
        self.handler = handler
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
                resetIdleTimer()
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
            var tooLarge = false
            var readyRequest: MCPHTTPRequest?

            receiveState.withLock { state in
                if let chunk, !chunk.isEmpty {
                    state.data.append(chunk)
                    resetIdleTimer()
                }
                guard state.data.count <= HTTPMessage.maxRequestBytes else {
                    tooLarge = true
                    return
                }
                if !state.headerFound {
                    if HTTPMessage.headerTerminatorEnd(in: state.data, searchingFrom: state.searchFrom) != nil {
                        state.headerFound = true
                    } else {
                        guard state.data.count <= HTTPMessage.maxHeaderBytes else {
                            tooLarge = true
                            return
                        }
                        // Resume the next search just before the tail, so a terminator split
                        // across a chunk boundary is still found — never re-scan from the start.
                        state.searchFrom = max(state.data.count - 3, 0)
                        return
                    }
                }
                readyRequest = HTTPMessage.parse(state.data)
            }

            if tooLarge {
                closeWithStatus(413)
                return
            }
            if let readyRequest {
                respond(to: readyRequest)
                return
            }
            guard error == nil, !isComplete else {
                connection.cancel()
                return
            }
            receive()
        }
    }

    /// `handler.handle` runs in an unstructured `Task` that this method does not itself await —
    /// deliberately: a `withTaskGroup`-based race would still block this connection's teardown on
    /// the slow task's eventual completion (structured concurrency awaits every child before the
    /// group returns, cancellation or not), which is exactly the "pinned forever" failure mode the
    /// timeout exists to prevent. Instead, a queue timer independently cancels the *connection*
    /// after `handlerTimeout`; a `Mutex`-guarded flag makes whichever of {timer, handler} arrives
    /// second a no-op, so a slow handler that eventually does return can never send a response onto
    /// a connection this already closed.
    private func respond(to request: MCPHTTPRequest) {
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
        queue.asyncAfter(deadline: .now() + Self.handlerTimeout, execute: timeoutWork)

        Task {
            let (status, body) = await handler.handle(request, peer: identity)
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

    /// Cancels `idleWork` and detaches `stateUpdateHandler`, so `finish()` (reached only via
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
    private func resetIdleTimer() {
        idleWork.withLock { previous in
            previous?.cancel()
            let work = DispatchWorkItem { [connection] in connection.cancel() }
            previous = work
            queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: work)
        }
    }
}
