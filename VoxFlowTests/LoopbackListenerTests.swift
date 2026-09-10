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
    func handle(_ request: MCPHTTPRequest, peer: MCPClientIdentity) async -> (status: Int, body: Data?) { (200, nil) }
}

/// Task 2 review, I1: `NWListener(using:on:)` does not throw on a busy port — the bind failure
/// surfaces asynchronously via `stateUpdateHandler`. This is the one `LoopbackListener` behaviour
/// the review calls out as testable without a full integration test, so it's no longer deferred to
/// Task 5.
@Suite("LoopbackListener port scan")
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
}
