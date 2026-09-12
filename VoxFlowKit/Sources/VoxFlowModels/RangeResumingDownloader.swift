import Foundation
import Synchronization
import VoxFlowCore

/// Production downloader: URLSession delivers bounded `Data` chunks to a serial delegate, which
/// writes them directly to the resumable partial file without a per-byte async sequence.
public struct RangeResumingDownloader: ModelDownloading {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func download(_ url: URL, to destination: URL,
                         progress: @Sendable @escaping (Int64, Int64) -> Void) async throws {
        guard !Task.isCancelled else { throw DownloadError.cancelled }
        let existing = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        var request = URLRequest(url: url)
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }

        let delegate = ChunkedDownloadDelegate(destination: destination, existing: existing, progress: progress)
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let transferSession = URLSession(configuration: session.configuration, delegate: delegate,
                                         delegateQueue: delegateQueue)
        defer { transferSession.invalidateAndCancel() }
        try await delegate.run(transferSession.dataTask(with: request))
    }
}

private final class ChunkedDownloadDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Void, any Error>?
        var task: URLSessionDataTask?
        var handle: FileHandle?
        var written: Int64
        var expectedTotal: Int64?
        var reportedTotal: Int64 = 0
        var cancelRequested = false
        var finished = false
    }

    private let destination: URL
    private let existing: Int64
    private let progress: @Sendable (Int64, Int64) -> Void
    private let state: Mutex<State>

    init(destination: URL, existing: Int64, progress: @Sendable @escaping (Int64, Int64) -> Void) {
        self.destination = destination
        self.existing = existing
        self.progress = progress
        state = Mutex(State(written: existing))
    }

    func run(_ task: URLSessionDataTask) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldStart = state.withLock { state in
                    state.continuation = continuation
                    state.task = task
                    return !state.cancelRequested
                }
                if shouldStart {
                    task.resume()
                } else {
                    task.cancel()
                    finish(.failure(DownloadError.cancelled))
                }
            }
        } onCancel: {
            cancel()
        }
    }

    private func cancel() {
        let task = state.withLock { state -> URLSessionDataTask? in
            guard !state.finished else { return nil }
            state.cancelRequested = true
            return state.task
        }
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if state.withLock({ $0.cancelRequested }) {
            completionHandler(.cancel)
            finish(.failure(DownloadError.cancelled))
            return
        }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(DownloadError.http(status: -1)))
            return
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            completionHandler(.cancel)
            finish(.failure(DownloadError.http(status: http.statusCode)))
            return
        }

        do {
            let resumed = http.statusCode == 206
            if !resumed || !FileManager.default.fileExists(atPath: destination.path) {
                _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: destination)
            if resumed { try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }
            state.withLock { state in
                state.handle = handle
                state.written = resumed ? existing : 0
                state.reportedTotal = state.written + max(http.expectedContentLength, 0)
                state.expectedTotal = http.expectedContentLength >= 0 ? state.written + http.expectedContentLength : nil
            }
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let outcome = state.withLock { state -> Result<(Int64, Int64)?, any Error> in
            guard !state.finished, let handle = state.handle else { return .success(nil) }
            do {
                try handle.write(contentsOf: data)
                state.written += Int64(data.count)
                return .success((state.written, state.reportedTotal))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let value):
            if let value { progress(value.0, value.1) }
        case .failure(let error):
            dataTask.cancel()
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let snapshot = state.withLock { ($0.cancelRequested, $0.written, $0.expectedTotal) }
        if snapshot.0 {
            finish(.failure(DownloadError.cancelled))
        } else if error != nil {
            finish(.failure(DownloadError.offline(bytesWritten: snapshot.1)))
        } else if let expected = snapshot.2, snapshot.1 != expected {
            finish(.failure(DownloadError.offline(bytesWritten: snapshot.1)))
        } else {
            finish(.success(()))
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        let resources = state.withLock { state -> (CheckedContinuation<Void, any Error>, FileHandle?)? in
            guard !state.finished, let continuation = state.continuation else { return nil }
            state.finished = true
            state.continuation = nil
            state.task = nil
            let handle = state.handle
            state.handle = nil
            return (continuation, handle)
        }
        guard let (continuation, handle) = resources else { return }
        try? handle?.close()
        continuation.resume(with: result)
    }
}
