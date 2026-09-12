import Foundation
import Observation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowModels

@Suite("Model request byte accounting")
struct ModelRequestByteCounterTests {
    @Test("tracking starts now and persisted totals survive relaunch")
    func persistence() {
        let store = InMemoryKeyValueStore()
        let start = Date(timeIntervalSince1970: 100)
        let counter = ModelRequestByteCounter(store: store, now: start)
        #expect(counter.bytesSent == 0)
        counter.record(headerBytes: 123, bodyBytes: 7)
        let restored = ModelRequestByteCounter(store: store, now: start.addingTimeInterval(90))
        #expect(restored.bytesSent == 130)
        #expect(restored.trackingStartedAt == start)
    }

    @Test("redirects and resumed attempts count sent headers/body; cached responses add nothing")
    func metrics() {
        let counter = ModelRequestByteCounter(store: InMemoryKeyValueStore())
        let firstAttempt = ModelRequestMetricsDelegate(counter: counter)
        firstAttempt.recordTransactions([
            FakeRequestMetrics(header: 120, body: 0),
            FakeRequestMetrics(header: 140, body: 10),
            FakeRequestMetrics(header: 40, body: 0, resourceFetchType: .unknown),
            FakeRequestMetrics(header: 999, body: 999, resourceFetchType: .localCache),
        ])
        // A failed or cancelled request still contributes its collected metrics. The retry
        // creates a fresh delegate; downloaded response payloads never enter this accounting.
        ModelRequestMetricsDelegate(counter: counter).recordTransactions([FakeRequestMetrics(header: 80, body: 0)])
        #expect(counter.bytesSent == 390)
    }

    @Test("chunked transfer accounting survives cancellation and counts retries without response bytes")
    func chunkedMetrics() async {
        let store = InMemoryKeyValueStore()
        let counter = ModelRequestByteCounter(store: store)
        let directory = TemporaryDirectory()
        let delegate = ChunkedDownloadDelegate(destination: directory.file("model.partial"), existing: 0,
                                               requestBytes: counter) { _, _ in }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://example.com/model")!)
        // A cancelled transfer can still report request bytes; its response payload never counts.
        let transfer = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await delegate.run(task)
        }
        await #expect(throws: DownloadError.cancelled) { try await transfer.value }
        delegate.recordRequestMetrics([
            FakeRequestMetrics(header: 120, body: 3),
            FakeRequestMetrics(header: 40, body: 0, resourceFetchType: .unknown),
            FakeRequestMetrics(header: 999, body: 999, resourceFetchType: .localCache),
        ])
        let retry = ChunkedDownloadDelegate(destination: directory.file("model.partial"), existing: 1_048_576,
                                            requestBytes: counter) { _, _ in }
        retry.recordRequestMetrics([FakeRequestMetrics(header: 130, body: 0)])
        #expect(counter.bytesSent == 293)
        #expect(ModelRequestByteCounter(store: store).bytesSent == 293)
    }

    @Test("footer reports the actual total and never claims unmeasured pre-upgrade traffic")
    func footer() {
        let counter = ModelRequestByteCounter(store: InMemoryKeyValueStore())
        #expect(counter.summary == "0 bytes sent since tracking began")
        counter.record(headerBytes: 1, bodyBytes: 0)
        #expect(counter.summary == "1 byte sent since tracking began")
        counter.record(headerBytes: 1233, bodyBytes: 0)
        #expect(counter.summary == "1234 bytes sent since tracking began")
    }

    @Test("concurrent callbacks persist every increment without lost updates")
    func concurrentRecording() async {
        let store = InMemoryKeyValueStore()
        let counter = ModelRequestByteCounter(store: store)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 { group.addTask { counter.record(headerBytes: 2, bodyBytes: 1) } }
        }
        #expect(counter.bytesSent == 600)
        #expect(ModelRequestByteCounter(store: store).bytesSent == 600)
    }

    @Test("invalid metrics cannot decrease a total and overflow saturates")
    func bounds() {
        let counter = ModelRequestByteCounter(store: InMemoryKeyValueStore())
        counter.record(headerBytes: 20, bodyBytes: -5)
        counter.record(headerBytes: -100, bodyBytes: 0)
        #expect(counter.bytesSent == 20)
        counter.record(headerBytes: .max, bodyBytes: .max)
        #expect(counter.bytesSent == .max)
    }

    @Test("the displayed observable total invalidates when measured bytes arrive")
    func observation() {
        let counter = ModelRequestByteCounter(store: InMemoryKeyValueStore())
        let changed = Mutex(false)
        withObservationTracking { _ = counter.bytesSent } onChange: { changed.withLock { $0 = true } }
        counter.record(headerBytes: 1, bodyBytes: 0)
        #expect(changed.withLock { $0 })
    }
}

private struct FakeRequestMetrics: SentRequestMetrics {
    let countOfRequestHeaderBytesSent: Int64
    let countOfRequestBodyBytesSent: Int64
    let resourceFetchType: URLSessionTaskMetrics.ResourceFetchType
    init(header: Int64, body: Int64, resourceFetchType: URLSessionTaskMetrics.ResourceFetchType = .networkLoad) {
        countOfRequestHeaderBytesSent = header
        countOfRequestBodyBytesSent = body
        self.resourceFetchType = resourceFetchType
    }
}
