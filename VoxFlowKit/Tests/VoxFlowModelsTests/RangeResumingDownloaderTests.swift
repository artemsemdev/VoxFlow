import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowModels

// URLProtocol owns this instance until `stopLoading`; delivery is confined to `deliveryQueue`, and
// the only cross-queue field (`stopped`) is protected by Mutex.
private final class DownloadURLProtocol: URLProtocol, @unchecked Sendable {
    enum Completion: Sendable { case finish, fail(URLError), controlledFail(URLError), hold }
    struct Script: Sendable {
        let status: Int
        let headers: [String: String]
        let chunks: [Data]
        var completion = Completion.finish
    }
    private struct State: Sendable {
        var script: Script?
        var rangeHeaders: [String?] = []
        var triggerFailure: (@Sendable () -> Void)?
    }
    private static let state = Mutex(State())
    private let stopped = Mutex(false)
    private let deliveryQueue = DispatchQueue(label: "dev.artemsem.voxflow.tests.download-protocol")

    static func install(_ script: Script) {
        state.withLock { $0 = State(script: script) }
    }

    static var rangeHeaders: [String?] { state.withLock { $0.rangeHeaders } }
    static func triggerFailure() {
        let action = state.withLock { $0.triggerFailure }
        action?()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let script = Self.state.withLock { state -> Script? in
            state.rangeHeaders.append(request.value(forHTTPHeaderField: "Range"))
            return state.script
        }
        guard let script,
              let response = HTTPURLResponse(url: request.url!, statusCode: script.status,
                                            httpVersion: "HTTP/1.1", headerFields: script.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        deliveryQueue.async { [self] in
            guard !stopped.withLock({ $0 }) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if case .controlledFail(let error) = script.completion {
                Self.state.withLock { state in
                    state.triggerFailure = { [weak self] in
                        self?.deliveryQueue.async { [weak self] in
                            guard let self, !self.stopped.withLock({ $0 }) else { return }
                            self.client?.urlProtocol(self, didFailWithError: error)
                        }
                    }
                }
            }
            for chunk in script.chunks {
                guard !stopped.withLock({ $0 }) else { return }
                client?.urlProtocol(self, didLoad: chunk)
            }
            deliveryQueue.async { [self] in complete(script) }
        }
    }

    override func stopLoading() { stopped.withLock { $0 = true } }

    private func complete(_ script: Script) {
        guard !stopped.withLock({ $0 }) else { return }
        switch script.completion {
        case .finish: client?.urlProtocolDidFinishLoading(self)
        case .fail(let error): client?.urlProtocol(self, didFailWithError: error)
        case .controlledFail: break
        case .hold: break
        }
    }
}

private final class DownloadProgressRecorder: Sendable {
    struct Value: Equatable, Sendable { let written: Int64; let total: Int64 }
    private struct State: Sendable {
        var values: [Value] = []
        var firstValueWaiter: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    var values: [Value] { state.withLock { $0.values } }
    func append(_ written: Int64, _ total: Int64) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.values.append(Value(written: written, total: total))
            defer { state.firstValueWaiter = nil }
            return state.firstValueWaiter
        }
        waiter?.resume()
    }

    func waitForFirst() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [self] in await firstValue(); return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return false
            }
            let observed = await group.next() ?? false
            group.cancelAll()
            return observed
        }
    }

    private func firstValue() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldWait = state.withLock { state in
                    guard state.values.isEmpty, !Task.isCancelled else { return false }
                    state.firstValueWaiter = continuation
                    return true
                }
                if !shouldWait { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                defer { state.firstValueWaiter = nil }
                return state.firstValueWaiter
            }
            waiter?.resume()
        }
    }
}

@Suite("Range-resuming downloader", .serialized)
struct RangeResumingDownloaderTests {
    private func downloader() -> RangeResumingDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadURLProtocol.self]
        return RangeResumingDownloader(session: URLSession(configuration: configuration))
    }

    @Test("writes callback data directly and reports durable progress")
    func chunks() async throws {
        DownloadURLProtocol.install(.init(status: 200, headers: ["Content-Length": "9"],
                                          chunks: [Data("abc".utf8), Data("defg".utf8), Data("hi".utf8)]))
        let directory = TemporaryDirectory()
        let destination = directory.file("model.partial")
        let progress = DownloadProgressRecorder()

        try await downloader().download(URL(string: "https://example.com/model.bin")!, to: destination,
                                        progress: progress.append)

        #expect(try Data(contentsOf: destination) == Data("abcdefghi".utf8))
        #expect(progress.values.last == .init(written: 9, total: 9))
        #expect(progress.values.count < 9)
        #expect(DownloadURLProtocol.rangeHeaders == [nil])
    }

    @Test("a partial file sends Range and appends a 206 response")
    func resumes() async throws {
        DownloadURLProtocol.install(.init(status: 206, headers: ["Content-Length": "4"],
                                          chunks: [Data("defg".utf8)]))
        let directory = TemporaryDirectory()
        let destination = directory.file("model.partial")
        try Data("abc".utf8).write(to: destination)
        let progress = DownloadProgressRecorder()

        try await downloader().download(URL(string: "https://example.com/model.bin")!, to: destination,
                                        progress: progress.append)

        #expect(try Data(contentsOf: destination) == Data("abcdefg".utf8))
        #expect(DownloadURLProtocol.rangeHeaders == ["bytes=3-"])
        #expect(progress.values == [.init(written: 7, total: 7)])
    }

    @Test("a server ignoring Range restarts the partial file")
    func restartsOnFullResponse() async throws {
        DownloadURLProtocol.install(.init(status: 200, headers: ["Content-Length": "3"],
                                          chunks: [Data("new".utf8)]))
        let directory = TemporaryDirectory()
        let destination = directory.file("model.partial")
        try Data("old-partial".utf8).write(to: destination)

        try await downloader().download(URL(string: "https://example.com/model.bin")!, to: destination) { _, _ in }

        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        #expect(DownloadURLProtocol.rangeHeaders == ["bytes=11-"])
    }

    @Test("an HTTP rejection preserves the existing partial")
    func httpFailure() async throws {
        DownloadURLProtocol.install(.init(status: 416, headers: [:], chunks: []))
        let directory = TemporaryDirectory()
        let destination = directory.file("model.partial")
        let partial = Data("keep me".utf8)
        try partial.write(to: destination)
        let progress = DownloadProgressRecorder()

        await #expect(throws: DownloadError.http(status: 416)) {
            try await downloader().download(URL(string: "https://example.com/model.bin")!,
                                            to: destination, progress: progress.append)
        }

        #expect(try Data(contentsOf: destination) == partial)
        #expect(progress.values.isEmpty)
        #expect(DownloadURLProtocol.rangeHeaders == ["bytes=7-"])
    }

}
