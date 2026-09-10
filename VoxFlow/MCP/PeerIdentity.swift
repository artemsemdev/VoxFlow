import Darwin
import Foundation
import Synchronization
import VoxFlowMCP

/// Resolves the OS process on the other end of a loopback connection, behind a protocol so tests
/// (and `LoopbackListener`) can inject a fake instead of touching real system process tables.
protocol PeerResolving: Sendable {
    /// `peerPort` is the *client's own* local port — what `LoopbackListener` sees as the accepted
    /// connection's peer port, since from the server's side "their local port" and "the port they
    /// connected from" are the same number. `serverPort` is VoxFlow's own bound port.
    ///
    /// Task 2 review ruling (I4): matching `peerPort` alone let a socket that merely *happens* to
    /// share that local port number — a listener, or a connection to somewhere else entirely — be
    /// mistaken for the real caller, and a `proc_listallpids` race (the real client exits and the
    /// kernel recycles its ephemeral port before this resolves) could durably mis-attribute an
    /// "Always allow" to an innocent app. The socket must now match **both** ends and be
    /// established.
    func resolveProcess(peerPort: UInt16, serverPort: UInt16) -> (pid: Int32, name: String, path: String)?
}

/// `libproc` resolution (spike notes §4), verified against a real loopback socket: no privileges,
/// no entitlement, works only because VoxFlow is unsandboxed (no `.entitlements` file). Walks every
/// process's open file descriptors looking for an *established* TCP socket whose local port matches
/// `peerPort` **and** whose foreign (remote) port matches `serverPort`, then reads that process's
/// name and executable path.
///
/// `proc_name`/`proc_pidpath` failing is expected and not exceptional (a process can vanish between
/// the port match and the name lookup, or refuse); `resolveProcess` returns `nil` when the name
/// can't be read for the one match found, or when a **second** socket also matches both ports (an
/// ambiguous result — an unidentified client is safer than a confidently wrong one; the approval
/// dialog handles `nil` as "Unknown app"). A missing `proc_pidpath` alone still yields an identity
/// with `path == ""` (the caller falls back to the name; see resolutions).
struct LibprocPeerResolver: PeerResolving {
    func resolveProcess(peerPort: UInt16, serverPort: UInt16) -> (pid: Int32, name: String, path: String)? {
        var match: (pid: Int32, name: String, path: String)?
        for pid in Self.allPIDs() {
            for descriptor in Self.fileDescriptors(for: pid) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                guard let info = Self.socketInfo(pid: pid, fd: descriptor.proc_fd) else { continue }
                guard Self.isEstablishedTCP(info) else { continue }
                guard Self.localPort(of: info) == peerPort, Self.foreignPort(of: info) == serverPort else { continue }
                guard match == nil else { return nil } // a second match: don't guess which one is real.
                guard let name = Self.name(for: pid) else { return nil }
                match = (pid: pid, name: name, path: Self.path(for: pid) ?? "")
            }
        }
        return match
    }

    private static func isEstablishedTCP(_ info: socket_fdinfo) -> Bool {
        Int(info.psi.soi_kind) == SOCKINFO_TCP && info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_ESTABLISHED
    }

    private static func localPort(of info: socket_fdinfo) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))
    }

    private static func foreignPort(of info: socket_fdinfo) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_fport))
    }

    /// Headroom above the first count: processes can start between the sizing call and the fetch.
    private static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let size = Int32(pids.count * MemoryLayout<Int32>.size)
        let actual = proc_listallpids(&pids, size)
        guard actual > 0 else { return [] }
        return Array(pids.prefix(min(Int(actual), pids.count)))
    }

    private static func fileDescriptors(for pid: Int32) -> [proc_fdinfo] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let count = Int(bufferSize) / MemoryLayout<proc_fdinfo>.size
        guard count > 0 else { return [] }
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(proc_fd: 0, proc_fdtype: 0), count: count)
        let actual = buffer.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard actual > 0 else { return [] }
        return Array(buffer.prefix(min(Int(actual) / MemoryLayout<proc_fdinfo>.size, buffer.count)))
    }

    private static func socketInfo(pid: Int32, fd: Int32) -> socket_fdinfo? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        let actual = withUnsafeMutableBytes(of: &info) { raw in
            proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, raw.baseAddress, size)
        }
        guard actual == size else { return nil }
        return info
    }

    private static func name(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return string(from: buffer)
    }

    /// `PROC_PIDPATHINFO_MAXSIZE` (`4 * MAXPATHLEN`) doesn't import from this SDK's macro, so the
    /// buffer size is spelled out directly.
    private static func path(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return string(from: buffer)
    }

    /// `String(cString:)` is deprecated on this SDK in favor of truncating at the null terminator
    /// and decoding the raw bytes directly.
    private static func string(from buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// The process on the other end of a connection, resolved **on demand and at most once**.
///
/// Final review F1: resolution walks every process's open file descriptors — measured at about
/// 5 ms and 14,000 syscalls per call — and the transport used to do it for every accepted
/// connection, before the request's bearer token had been looked at. A bare `connect()` loop from
/// any local process therefore bought unbounded pre-auth CPU work on the listener's own queue.
/// Wrapping it here lets the transport hand over something cheap and lets `MCPToolRunner` pay the
/// cost only where it genuinely needs a name: deciding whether an *authenticated* caller's client
/// has been approved.
final class MCPPeer: Sendable {
    private let resolve: @Sendable () -> MCPClientIdentity
    private let cached = Mutex<MCPClientIdentity?>(nil)

    init(_ resolve: @escaping @Sendable () -> MCPClientIdentity) { self.resolve = resolve }

    /// Convenience for tests and any caller that already knows the identity.
    init(_ identity: MCPClientIdentity) { self.resolve = { identity } }

    /// The resolution runs inside the lock, so two concurrent readers cannot both pay for the walk.
    /// One request per connection makes the contention theoretical.
    func identity() -> MCPClientIdentity {
        cached.withLock { value in
            if let value { return value }
            let resolved = resolve()
            value = resolved
            return resolved
        }
    }
}
