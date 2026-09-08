import Foundation
import VoxFlowCore

/// Production downloader: HTTP with a `Range` header so an interrupted transfer resumes from
/// the bytes already on disk. Not unit-tested (network); exercised by the app in phase 2.
public struct RangeResumingDownloader: ModelDownloading {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func download(_ url: URL, to destination: URL, progress: @Sendable @escaping (Int64, Int64) -> Void) async throws {
        let existing = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        var request = URLRequest(url: url)
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw DownloadError.offline(bytesWritten: existing)
        }
        guard let http = response as? HTTPURLResponse else { throw DownloadError.http(status: -1) }
        guard http.statusCode == 200 || http.statusCode == 206 else { throw DownloadError.http(status: http.statusCode) }
        let resumed = http.statusCode == 206
        let total = (resumed ? existing : 0) + max(http.expectedContentLength, 0)

        if !resumed || !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        if resumed { try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }

        var written = resumed ? existing : 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    progress(written, total)
                }
                try Task.checkCancellation()
            }
        } catch is CancellationError {
            try? handle.write(contentsOf: buffer)
            throw DownloadError.cancelled
        } catch {
            try? handle.write(contentsOf: buffer)
            throw DownloadError.offline(bytesWritten: written + Int64(buffer.count))
        }
        try handle.write(contentsOf: buffer)
        written += Int64(buffer.count)
        progress(written, total)
    }
}
