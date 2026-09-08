import CryptoKit
import Foundation

public enum SHA256File {
    /// Streams the file in 1 MiB chunks so multi-GB models never sit in memory.
    public static func hexDigest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Hex digest of in-memory bytes (test fixtures; production streams from disk above).
    public static func hexDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
