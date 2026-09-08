import Foundation
import Testing
import VoxFlowCore
import VoxFlowTestSupport
@testable import VoxFlowFiles

/// `AudioDurationProviding` that parks every call until `releaseAll()`, letting a test observe (and
/// wait for) how many concurrent callers are currently blocked in `duration(of:)` — same
/// continuation-park pattern as `FakeFileTranscriber.park`.
actor GatedDuration: AudioDurationProviding {
    private var pending: [CheckedContinuation<TimeInterval, any Error>] = []
    private var callerCount = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    var totalCalls: Int { callerCount }

    func duration(of url: URL) async throws -> TimeInterval {
        callerCount += 1
        notifyWaiters()
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    /// Resolves once at least `count` calls to `duration(of:)` are currently parked.
    func waitForCallers(_ count: Int) async {
        if callerCount >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func releaseAll() {
        let toResume = pending
        pending = []
        for continuation in toResume { continuation.resume(returning: 0) }
    }

    private func notifyWaiters() {
        waiters.removeAll { waiter in
            guard callerCount >= waiter.count else { return false }
            waiter.continuation.resume()
            return true
        }
    }
}

@Suite("FileQueue")
struct FileQueueTests {
    static func doc(_ url: URL) -> TranscriptDocument {
        TranscriptDocument(sourceURL: url, transcript: Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "ok")!], language: "en"),
                           modelID: "m", audioDuration: 60, processingTime: 1, createdAt: Date(timeIntervalSince1970: 0))
    }
    let a = URL(fileURLWithPath: "/tmp/a.m4a")
    let b = URL(fileURLWithPath: "/tmp/b.mp3")
    let bad = URL(fileURLWithPath: "/tmp/notes.pages")

    func makeQueue(_ transcriber: FakeFileTranscriber, durations: [URL: TimeInterval] = [:]) -> FileQueue {
        FileQueue(transcriber: transcriber, durations: FakeAudioDuration(durations),
                  supportedExtensions: ["m4a", "mp3", "wav"], options: { TranscriptionOptions() })
    }

    /// Collects events until `count` `finished` events arrived (bounded by the test's timeout).
    static func awaitFinished(_ queue: FileQueue, count: Int) async -> [QueueItem] {
        var finished: [QueueItem] = []
        for await event in await queue.subscribe() {
            if case .finished(let item) = event { finished.append(item) }
            if finished.count == count { break }
        }
        return finished
    }

    @Test("adds rows in order, reads durations, rejects unsupported types on drop")
    func add() async throws {
        let queue = makeQueue(FakeFileTranscriber(), durations: [a: 120, b: 30])
        let items = await queue.add([a, bad, b])
        #expect(items.map(\.url) == [a, bad, b])
        #expect(items[1].status == .failed(.unsupportedType("pages")))
        #expect(await queue.totalDuration == 150)
        #expect(await queue.items.map(\.duration) == [120, nil, 30])
    }

    @Test("the same file dropped twice is one row with a 2× badge")
    func duplicates() async {
        let queue = makeQueue(FakeFileTranscriber())
        await queue.add([a])
        await queue.add([URL(fileURLWithPath: "/tmp/../tmp/a.m4a")])
        let items = await queue.items
        #expect(items.count == 1)
        #expect(items[0].duplicates == 2)
    }

    @Test("two overlapping adds of the same file produce one row with a 2× badge")
    func concurrentAddSameFile() async {
        // The fix's whole point is that the dedupe check and the row's append happen with no
        // suspension between them, so whichever of these two `add` calls runs first reserves the
        // row *before* either one could await a duration lookup — the other sees that row already
        // there and never calls `duration(of:)` itself. Exactly one caller ever reaches the gate;
        // that is the fixed behavior, not a fluke of this test, so we only wait for one.
        let gate = GatedDuration()
        let queue = FileQueue(transcriber: FakeFileTranscriber(), durations: gate,
                              supportedExtensions: ["m4a"], options: { TranscriptionOptions() })
        async let first: [QueueItem] = queue.add([a])
        async let second: [QueueItem] = queue.add([a])
        await gate.waitForCallers(1)
        await gate.releaseAll()
        _ = await (first, second)
        let items = await queue.items
        #expect(items.count == 1 && items[0].duplicates == 2)
        #expect(await gate.totalCalls == 1)
    }

    @Test("re-dropping a failed or cancelled file bumps the badge and re-queues it; done files get a new row")
    func redropAfterFailure() async throws {
        let transcriber = FakeFileTranscriber()
        await transcriber.script(a, .failure(.decodeFailed("corrupt")))
        await transcriber.script(b, .document(Self.doc(b)))
        let queue = makeQueue(transcriber)
        await queue.add([a, b])
        async let finished = Self.awaitFinished(queue, count: 2)
        await queue.start()
        _ = await finished
        await queue.waitUntilIdle()
        await queue.add([a, b])
        let items = await queue.items
        #expect(items.count == 3)
        #expect(items[0].url == a && items[0].status == .queued && items[0].duplicates == 2)
        #expect(items[2].url == b && items[2].status == .queued && items[2].duplicates == 1)   // done → new row
    }

    @Test("processes sequentially, skips failures and keeps going, emits finished events")
    func sequentialSkipFailed() async throws {
        let transcriber = FakeFileTranscriber()
        await transcriber.script(a, .failure(.decodeFailed("corrupt")))
        await transcriber.script(b, .document(Self.doc(b)))
        let queue = makeQueue(transcriber)
        await queue.add([a, b])
        async let finished = Self.awaitFinished(queue, count: 2)
        await queue.start()
        let done = await finished
        #expect(done.map(\.url) == [a, b])
        #expect(done[0].status == .failed(.decodeFailed("corrupt")))
        if case .done(let document) = done[1].status { #expect(document.sourceURL == b) } else { Issue.record("b should be done") }
        #expect(await transcriber.calls == [a, b])
        #expect(await queue.isRunning == false)
    }

    @Test("progress is coalesced and monotonic")
    func progress() async throws {
        let transcriber = FakeFileTranscriber()
        await transcriber.script(a, .document(Self.doc(a)))
        let queue = makeQueue(transcriber)
        let item = await queue.add([a])[0]
        var seen: [Double] = []
        // Subscribe before `start()`: `subscribe()` registers the continuation as a side effect of
        // this actor call, and that registration must happen before `start()` publishes the
        // first event, or it is missed by this particular subscriber (each subscriber only sees
        // events published after it registered — there is no pre-subscription buffer).
        // Calling `await queue.subscribe()` *inside* the `Task {}` closure races `start()` below —
        // a plain `Task` isn't guaranteed to run before the next line the way `async let` is.
        let stream = await queue.subscribe()
        let collector = Task {
            for await event in stream {
                if case .changed(let changed) = event, case .running(let p) = changed.status { seen.append(p) }
                if case .finished = event { break }
            }
            return seen
        }
        await queue.start()
        let values = await collector.value
        #expect(values == [0, 0.25, 0.5, 0.75])
        #expect(await queue.progress(of: item.id) == nil)     // finished items report no progress
    }

    @Test("cancelling the running item moves on to the next; retry re-queues it")
    func cancelAndRetry() async throws {
        let transcriber = FakeFileTranscriber()
        await transcriber.hold(a)
        await transcriber.script(a, .document(Self.doc(a)))
        await transcriber.script(b, .document(Self.doc(b)))
        let queue = makeQueue(transcriber)
        let items = await queue.add([a, b])
        async let finished = Self.awaitFinished(queue, count: 1)
        await queue.start()
        await transcriber.waitUntilHeld(a)
        await queue.cancel(id: items[0].id)
        let done = await finished
        #expect(done[0].url == b)
        #expect(await queue.items[0].status == .cancelled)
        await transcriber.script(a, .document(Self.doc(a)))
        async let retried = Self.awaitFinished(queue, count: 1)
        await queue.retry(id: items[0].id)
        await queue.start()
        #expect(await retried[0].url == a)
        #expect(await transcriber.calls == [a, b, a])
    }

    @Test("remove cancels a running item and drops the row")
    func remove() async throws {
        let transcriber = FakeFileTranscriber()
        await transcriber.hold(a)
        await transcriber.script(a, .document(Self.doc(a)))
        let queue = makeQueue(transcriber)
        let item = await queue.add([a])[0]
        await queue.start()
        await transcriber.waitUntilHeld(a)
        await queue.remove(id: item.id)
        #expect(await queue.items.isEmpty)
        await queue.waitUntilIdle()
        #expect(await queue.isRunning == false)
    }

    @Test("start is idempotent while running")
    func startIdempotent() async throws {
        let transcriber = FakeFileTranscriber()
        await transcriber.hold(a)
        await transcriber.script(a, .document(Self.doc(a)))
        let queue = makeQueue(transcriber)
        await queue.add([a])
        await queue.start()
        await transcriber.waitUntilHeld(a)
        await queue.start()
        await transcriber.release(a)
        _ = await Self.awaitFinished(queue, count: 1)
        #expect(await transcriber.calls == [a])
    }

    @Test("idle event and waitUntilIdle after the last job")
    func idleAfterLastJob() async throws {
        let transcriber = FakeFileTranscriber()
        await transcriber.script(a, .document(Self.doc(a)))
        let queue = makeQueue(transcriber)
        await queue.add([a])
        let stream = await queue.subscribe()
        let collector = Task { () -> Bool in
            var sawFinished = false
            for await event in stream {
                if case .finished = event { sawFinished = true }
                if case .idle = event { return sawFinished }
            }
            return false
        }
        await queue.start()
        let idleArrivedAfterFinished = await collector.value
        #expect(idleArrivedAfterFinished)
        await queue.waitUntilIdle()
        #expect(await queue.isRunning == false)
    }
}
