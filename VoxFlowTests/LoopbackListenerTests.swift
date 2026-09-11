import Darwin
import Foundation
import Testing
import VoxFlowMCP
@testable import VoxFlow

/// `LoopbackListener`'s connection-framing behaviour is exercised only by the Task 5 integration
/// test (it opens a real socket); here we only assert the transport-level error copy, which is
/// pure.
@Suite("MCPServerError")
struct MCPServerErrorTests {
    @Test("noFreePort's message names the port range")
    func noFreePortMessage() {
        #expect(MCPServerError.noFreePort.message == "VoxFlow couldn't find a free port for the MCP server (7331–7340 are all in use).")
    }
}

private struct FakePeerResolver: PeerResolving {
    func resolveProcess(peerPort: UInt16, serverPort: UInt16) -> (pid: Int32, name: String, path: String)? { nil }
}

private struct FakeRequestHandler: MCPRequestHandling {
    func handle(_ request: MCPHTTPRequest, peer: MCPPeer) async -> (status: Int, body: Data?) { (200, nil) }
}

/// Task 2 review, I1: `NWListener(using:on:)` does not throw on a busy port — the bind failure
/// surfaces asynchronously via `stateUpdateHandler`. This is the one `LoopbackListener` behaviour
/// the review calls out as testable without a full integration test, so it's no longer deferred to
/// Task 5.
@Suite("LoopbackListener port scan", .enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_MCP_INTEGRATION"] == "1",
       "Set VOXFLOW_MCP_INTEGRATION=1 to run real loopback socket tests"))
struct LoopbackListenerPortScanTests {
    @Test("a busy port is skipped and the scan lands on the next free one")
    func skipsBusyPort() async throws {
        // A real POSIX socket bound and listening on a kernel-chosen loopback port simulates
        // "port taken" without hardcoding a port number that might collide with something else
        // running on this machine.
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        try #require(fd >= 0)
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0 // let the kernel choose a free ephemeral port
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bindResult == 0)
        try #require(listen(fd, 1) == 0)

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &boundLen)
            }
        }
        try #require(nameResult == 0)
        let occupiedPort = UInt16(bigEndian: boundAddr.sin_port)
        try #require(occupiedPort < UInt16.max) // astronomically unlikely, but keep the +1 below safe
        let nextPort = occupiedPort + 1

        let listener = LoopbackListener(portRange: occupiedPort...nextPort, resolver: FakePeerResolver(), handler: FakeRequestHandler())
        try await listener.start()
        let bound = await listener.boundPort
        #expect(bound == nextPort) // the occupied port was skipped; the scan landed on the next one.
        await listener.stop()
    }

    /// A free loopback port, found by binding to port 0 (the kernel picks one) and immediately
    /// releasing it. Small race window between that release and a later real bind, same as
    /// `skipsBusyPort`'s already-accepted testing style.
    static func freeLoopbackPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        try #require(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bindResult == 0)
        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &boundLen)
            }
        }
        try #require(nameResult == 0)
        return UInt16(bigEndian: boundAddr.sin_port)
    }

    /// Whether a fresh POSIX socket can bind `port` on loopback right now — the same real-OS check
    /// `skipsBusyPort` relies on, used here in reverse to prove a port was **not** left orphaned.
    static func canBind(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = port.bigEndian
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }


}

/// Task 2 re-review round 2, N1: `start()` suspends (it awaits each candidate's `.ready`/`.failed`),
/// so actor isolation alone doesn't make it reentrancy-safe. Two concurrent calls, or a `stop()`
/// racing an in-flight call, could each bind a port and leave one of them orphaned — bound, live,
/// and unreachable by `stop()`, because only the last-assigned `listener` is ever cancelled.
@Suite("LoopbackListener start() reentrancy", .enabled(if: ProcessInfo.processInfo.environment["VOXFLOW_MCP_INTEGRATION"] == "1",
       "Set VOXFLOW_MCP_INTEGRATION=1 to run real loopback socket tests"))
struct LoopbackListenerReentrancyTests {
    @Test("two concurrent start() calls bind exactly one port; the other candidate stays free")
    func concurrentStartsBindOnlyOnePort() async throws {
        let firstPort = try LoopbackListenerPortScanTests.freeLoopbackPort()
        try #require(firstPort < UInt16.max)
        let secondPort = firstPort + 1

        let listener = LoopbackListener(portRange: firstPort...secondPort, resolver: FakePeerResolver(), handler: FakeRequestHandler())

        async let first: Void = try listener.start()
        async let second: Void = try listener.start()
        _ = try await (first, second)

        let bound = await listener.boundPort
        try #require(bound != nil)
        let otherCandidate = bound == firstPort ? secondPort : firstPort

        // If the two concurrent calls had each bound their own listener (the reentrancy bug), the
        // "other" candidate would also be live, orphaned, and unreachable by stop() — a fresh bind
        // on it would then fail. Fixed, both calls share one attempt, so it must still be free.
        #expect(LoopbackListenerPortScanTests.canBind(port: otherCandidate))

        await listener.stop()
    }

    @Test("a second start() after the listener is already running is a no-op")
    func secondStartAfterRunningIsNoOp() async throws {
        let port = try LoopbackListenerPortScanTests.freeLoopbackPort()
        let listener = LoopbackListener(portRange: port...port, resolver: FakePeerResolver(), handler: FakeRequestHandler())

        try await listener.start()
        let firstBound = await listener.boundPort
        try await listener.start() // should return immediately without re-scanning.
        let secondBound = await listener.boundPort

        #expect(firstBound == secondBound)
        await listener.stop()
    }
}
