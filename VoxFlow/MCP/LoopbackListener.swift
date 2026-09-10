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
    private let portRange: ClosedRange<UInt16>
    private let resolver: any PeerResolving
    private let handler: any MCPRequestHandling
    private var listener: NWListener?

    private(set) var boundPort: UInt16?

    init(portRange: ClosedRange<UInt16> = 7331...7340, resolver: any PeerResolving, handler: any MCPRequestHandling) {
        self.portRange = portRange
        self.resolver = resolver
        self.handler = handler
    }

    /// Tries each port in `portRange` in order and binds the first one that succeeds.
    func start() throws {
        for candidate in portRange {
            guard let port = NWEndpoint.Port(rawValue: candidate) else { continue }
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            guard let newListener = try? NWListener(using: parameters, on: port) else { continue }

            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { await self.accept(connection) }
            }
            newListener.start(queue: .main)
            listener = newListener
            boundPort = candidate
            return
        }
        throw MCPServerError.noFreePort
    }

    func stop() {
        listener?.cancel()
        listener = nil
        boundPort = nil
    }

    private func accept(_ connection: NWConnection) {
        // `connection.endpoint` is the remote peer for a connection handed to a listener's
        // `newConnectionHandler` — NWConnection has no separate `remoteEndpoint`; that name
        // belongs to `NWConnectionGroup.Message`/`NWPath`, not this type.
        guard isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        // Empty name signals "resolution failed entirely" to the caller (per the resolutions
        // note, substituting display copy like "Unknown app" is Task 3's job, not the transport's).
        let identity: MCPClientIdentity
        if let port = remotePort(of: connection), let resolved = resolver.resolveProcess(localPort: port) {
            identity = MCPClientIdentity(name: resolved.name, path: resolved.path, pid: resolved.pid)
        } else {
            identity = MCPClientIdentity(name: "", path: "", pid: nil)
        }
        ConnectionHandler(connection: connection, queue: .main, identity: identity, handler: handler).start()
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
final class ConnectionHandler: Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let identity: MCPClientIdentity
    private let handler: any MCPRequestHandling
    private let buffer = Mutex(Data())

    init(connection: NWConnection, queue: DispatchQueue, identity: MCPClientIdentity, handler: any MCPRequestHandling) {
        self.connection = connection
        self.queue = queue
        self.identity = identity
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            if case .ready = state { receive() }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] chunk, _, isComplete, error in
            if let chunk, !chunk.isEmpty {
                buffer.withLock { $0.append(chunk) }
            }
            if let request = buffer.withLock({ HTTPMessage.parse($0) }) {
                respond(to: request)
                return
            }
            guard error == nil, !isComplete else {
                connection.cancel()
                return
            }
            receive()
        }
    }

    private func respond(to request: MCPHTTPRequest) {
        Task {
            let (status, body) = await handler.handle(request, peer: identity)
            let response = HTTPMessage.write(status: status, body: body)
            connection.send(content: response, completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }
    }
}
