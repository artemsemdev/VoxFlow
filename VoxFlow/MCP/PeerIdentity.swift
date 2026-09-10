import Darwin
import Foundation

/// Resolves the OS process on the other end of a loopback connection, behind a protocol so tests
/// (and `LoopbackListener`) can inject a fake instead of touching real system process tables.
protocol PeerResolving: Sendable {
    /// `localPort` is the *client's own* local port — which is what `LoopbackListener` sees as the
    /// accepted connection's peer port, since from the server's side "their local port" and "the
    /// port they connected from" are the same number.
    func resolveProcess(localPort: UInt16) -> (pid: Int32, name: String, path: String)?
}

/// `libproc` resolution (spike notes §4), verified against a real loopback socket: no privileges,
/// no entitlement, works only because VoxFlow is unsandboxed (no `.entitlements` file). Walks every
/// process's open file descriptors looking for a TCP socket whose local port matches, then reads
/// that process's name and executable path.
///
/// `proc_name`/`proc_pidpath` failing is expected and not exceptional (a process can vanish between
/// the port match and the name lookup, or refuse); `resolveProcess` returns `nil` only when the name
/// itself can't be read — a missing `proc_pidpath` alone still yields an identity with `path == ""`
/// (the caller falls back to the name; see resolutions).
struct LibprocPeerResolver: PeerResolving {
    func resolveProcess(localPort: UInt16) -> (pid: Int32, name: String, path: String)? {
        for pid in Self.allPIDs() {
            for descriptor in Self.fileDescriptors(for: pid) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                guard let info = Self.socketInfo(pid: pid, fd: descriptor.proc_fd) else { continue }
                guard Int(info.psi.soi_kind) == SOCKINFO_TCP else { continue }
                let rawPort = UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
                guard UInt16(bigEndian: rawPort) == localPort else { continue }
                guard let name = Self.name(for: pid) else { return nil }
                return (pid: pid, name: name, path: Self.path(for: pid) ?? "")
            }
        }
        return nil
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
