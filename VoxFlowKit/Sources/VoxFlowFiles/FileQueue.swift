import Foundation
import VoxFlowCore

public struct QueueItem: Identifiable, Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case queued
        case running(progress: Double)
        case done(TranscriptDocument)
        case failed(FileTranscriptionError)
        case cancelled
    }

    public let id: UUID
    public let url: URL
    public var duration: TimeInterval?
    public var duplicates: Int
    public var status: Status

    public var isFinished: Bool {
        switch status {
        case .done, .failed: true
        default: false
        }
    }

    /// `true` only for a completed transcription — the one status `add` treats as "this file is
    /// done with, drop it again as a new row" rather than something to collapse into.
    var isDone: Bool {
        if case .done = status { return true }
        return false
    }
}

/// `.cancelled` rows emit `.changed` only (no `.finished`); terminal rows (`.done`/`.failed`) emit
/// `.changed` then `.finished`. `.idle` arrives once after the worker's last job, whether the queue
/// ran dry or every row is done/failed/cancelled.
public enum FileQueueEvent: Sendable, Equatable {
    case added(QueueItem)
    case changed(QueueItem)
    case removed(UUID)
    case finished(QueueItem)
    case idle
}

/// The Files page's queue (design MW-06): sequential, failed rows skipped, duplicates collapsed.
public actor FileQueue {
    public private(set) var items: [QueueItem] = []
    public private(set) var isRunning = false

    private let transcriber: any FileTranscribing
    private let durations: any AudioDurationProviding
    private let supportedExtensions: Set<String>
    private let options: @Sendable () -> TranscriptionOptions
    private var worker: Task<Void, Never>?
    private var currentJob: Task<Void, Never>?
    private var currentID: UUID?
    private var subscribers: [UUID: AsyncStream<FileQueueEvent>.Continuation] = [:]
    private var lastPublishedProgress: [UUID: Double] = [:]

    public init(transcriber: any FileTranscribing, durations: any AudioDurationProviding,
                supportedExtensions: Set<String>, options: @Sendable @escaping () -> TranscriptionOptions) {
        self.transcriber = transcriber
        self.durations = durations
        self.supportedExtensions = supportedExtensions
        self.options = options
    }

    /// Multi-subscriber event stream: each call registers its own continuation, live until the
    /// caller stops iterating (or the queue is deallocated), independent of every other subscriber.
    public func subscribe() -> AsyncStream<FileQueueEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<FileQueueEvent>.makeStream(bufferingPolicy: .unbounded)
        subscribers[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.unsubscribe(id) }
        }
        return stream
    }

    private func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    public var totalDuration: TimeInterval { items.compactMap(\.duration).reduce(0, +) }

    public func progress(of id: UUID) -> Double? {
        if case .running(let progress)? = items.first(where: { $0.id == id })?.status { return progress }
        return nil
    }

    /// Adds files, standardizing each path first. A URL that matches an existing row which isn't
    /// `.done` collapses into that row instead of creating a new one: `duplicates` is bumped, and
    /// if the row was `.failed`/`.cancelled` it is also re-queued (status → `.queued`) — the
    /// user's natural "drop it again to try again". A `.queued`/`.running` row is left running;
    /// only its badge changes. A URL matching only a `.done` row gets a fresh row instead, since
    /// that file's own transcript already exists and re-dropping means starting over on a new one.
    ///
    /// For a brand-new URL the row is appended and `.added` published *before* the duration lookup
    /// is awaited — the dedupe check and the append happen with no suspension between them, so a
    /// second `add` racing on the same URL always sees the row already there instead of also
    /// passing the dedupe check and creating a second one.
    @discardableResult
    public func add(_ urls: [URL]) async -> [QueueItem] {
        var added: [QueueItem] = []
        for raw in urls {
            let url = raw.standardizedFileURL
            if let index = items.firstIndex(where: { $0.url == url && !$0.isDone }) {
                items[index].duplicates += 1
                switch items[index].status {
                case .failed, .cancelled: items[index].status = .queued
                default: break
                }
                publish(.changed(items[index]))
                added.append(items[index])
                continue
            }
            let ext = url.pathExtension.lowercased()
            let item = QueueItem(id: UUID(), url: url, duration: nil, duplicates: 1,
                                 status: supportedExtensions.contains(ext) ? .queued : .failed(.unsupportedType(ext)))
            items.append(item)
            publish(.added(item))
            if case .failed = item.status { publish(.finished(item)) }
            if case .queued = item.status {
                let duration = try? await durations.duration(of: url)
                update(item.id) { $0.duration = duration }
            }
            added.append(items.first(where: { $0.id == item.id }) ?? item)
        }
        return added
    }

    public func remove(id: UUID) {
        if currentID == id { currentJob?.cancel() }
        items.removeAll { $0.id == id }
        publish(.removed(id))
    }

    public func cancel(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].status {
        case .queued:
            items[index].status = .cancelled
            publish(.changed(items[index]))
        case .running:
            guard currentID == id else { return }
            currentJob?.cancel()      // the job's catch marks the row cancelled
        default:
            break
        }
    }

    public func retry(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].status {
        case .failed, .cancelled:
            items[index].status = .queued
            publish(.changed(items[index]))
        default:
            break
        }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        worker = Task { await self.runLoop() }
    }

    /// Waits for the current worker (if any) to finish its run — including the `.idle` event it
    /// publishes at the end. Captures the task before awaiting, so it is fine that `runLoop` nils
    /// the field before this returns.
    public func waitUntilIdle() async {
        if let worker { await worker.value }
    }

    // MARK: Worker

    private func runLoop() async {
        while let index = items.firstIndex(where: { $0.status == .queued }) {
            let item = items[index]
            currentID = item.id
            update(item.id) { $0.status = .running(progress: 0) }
            lastPublishedProgress[item.id] = 0
            let job = Task { await self.transcribe(item) }
            currentJob = job
            await job.value
            currentJob = nil
            currentID = nil
        }
        isRunning = false
        worker = nil
        publish(.idle)
    }

    /// Runs one job and applies its terminal status. Progress reports arrive on the transcriber's
    /// callback thread and would otherwise race the `.done`/`.failed` update applied right after
    /// `transcribe` returns (the callback's actor hop can land after the terminal state). To keep
    /// ordering deterministic, the callback only feeds a per-job `AsyncStream<Double>`; a child task
    /// drains that stream through `report(_:progress:)` on the actor, and we `finish()` the stream
    /// and `await` that child task *before* applying the terminal status — so every `.changed`
    /// progress event the transcriber reported is guaranteed to have already gone through `report`
    /// (and thus been published, if it passed the coalescing threshold) by the time `.done`,
    /// `.failed`, or `.cancelled` is applied and `.finished` is published.
    private func transcribe(_ item: QueueItem) async {
        let (progressStream, progressContinuation) = AsyncStream<Double>.makeStream(bufferingPolicy: .unbounded)
        let progressTask = Task {
            for await value in progressStream {
                self.report(item.id, progress: value)
            }
        }
        defer { lastPublishedProgress[item.id] = nil }

        func drainProgress() async {
            progressContinuation.finish()
            await progressTask.value
        }

        do {
            let document = try await transcriber.transcribe(item.url, options: options()) { progress in
                progressContinuation.yield(progress)
            }
            await drainProgress()
            update(item.id) { $0.status = .done(document) }
            if let finished = items.first(where: { $0.id == item.id }) { publish(.finished(finished)) }
        } catch FileTranscriptionError.cancelled {
            await drainProgress()
            update(item.id) { $0.status = .cancelled }
        } catch is CancellationError {
            await drainProgress()
            update(item.id) { $0.status = .cancelled }
        } catch let error as FileTranscriptionError {
            await drainProgress()
            update(item.id) { $0.status = .failed(error) }
            if let finished = items.first(where: { $0.id == item.id }) { publish(.finished(finished)) }
        } catch {
            await drainProgress()
            update(item.id) { $0.status = .failed(.engineFailed(String(describing: error))) }
            if let finished = items.first(where: { $0.id == item.id }) { publish(.finished(finished)) }
        }
    }

    private func report(_ id: UUID, progress: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .running = items[index].status else { return }
        let clamped = min(max(progress, 0), 1)
        guard clamped - (lastPublishedProgress[id] ?? -1) >= 0.01 else { return }
        lastPublishedProgress[id] = clamped
        items[index].status = .running(progress: clamped)
        publish(.changed(items[index]))
    }

    private func update(_ id: UUID, _ change: (inout QueueItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        publish(.changed(items[index]))
    }

    private func publish(_ event: FileQueueEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }
}
