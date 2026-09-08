import Foundation
import Synchronization
import VoxFlowCore
import VoxFlowFiles
import VoxFlowModels

/// State and rules of the Files page (design 1c Files, MW-06, MW-06c, MW-06x, 3e). Views render it; nothing else decides.
@Observable @MainActor
final class FilesViewModel {
    enum Confirmation: Equatable {
        /// MW-06c: stop the running file? Only asked above 10 % progress.
        case stop(QueueItem, progress: Double)
        /// 3e "huge input": more than 4 hours in one drop.
        case longAudio(urls: [URL], hours: Double)
    }

    struct ExportedResult: Equatable {
        let item: QueueItem
        let document: TranscriptDocument
        let url: URL?
    }

    static let stopConfirmationThreshold = 0.10
    static let longAudioThresholdHours = 4.0
    /// Measured on an M1 Max with large-v3-turbo (ADR-002); used for the "about N min" estimate only.
    static let estimatedRealTimeFactor = 0.063
    static let uiRefreshInterval: TimeInterval = 1

    private(set) var items: [QueueItem] = []
    var confirmation: Confirmation?
    var selected: ExportedResult?
    private(set) var needsModel = false
    var isDragOver = false
    /// The number of items being dragged, shown in the overlay copy while `isDragOver` is true
    /// (design MW-06g, I3) — set by `FilesDropDelegate.dropEntered`, cleared on `dropExited`.
    var dragCount = 0
    private(set) var etaSeconds: [UUID: TimeInterval] = [:]

    private let queue: FileQueue
    private let settings: FilesSettings
    private let modelStore: ModelStore
    private let durations: any AudioDurationProviding
    private let exports: ExportCoordinator
    private let now: () -> Date
    private var estimators: [UUID: ETAEstimator] = [:]
    private var lastRender: [UUID: Date] = [:]
    /// Boxed outside MainActor isolation so `deinit` (which is `nonisolated` and may run on any
    /// thread) can cancel it without an isolation assertion. Never touched from `apply`/actions —
    /// only set once in `init` and read in `deinit`.
    private nonisolated let eventTask = Mutex<Task<Void, Never>?>(nil)

    init(queue: FileQueue, settings: FilesSettings, modelStore: ModelStore, durations: any AudioDurationProviding,
         exports: ExportCoordinator, now: @escaping () -> Date = { Date() }) {
        self.queue = queue
        self.settings = settings
        self.modelStore = modelStore
        self.durations = durations
        self.exports = exports
        self.now = now
        // `[weak self]` only helps if nothing downstream re-establishes a *strong* reference across
        // a suspension point. `guard let self else { return }` at the top of an async closure does
        // exactly that — it shadows `self` with a strong local for the rest of the closure body, so
        // the still-running `for await` loop below would keep the view model alive forever (its own
        // subscription never lets the loop return on its own). Every touch of `self` here is instead
        // scoped to a single `if`/`guard` so the strong reference never survives a suspension: the
        // loop re-checks `self` fresh on every iteration and lets the object deallocate — and the
        // loop then observes cancellation on the *next* iteration — the moment nothing else holds it.
        let task = Task { [weak self] in
            let stream = await queue.subscribe()
            let seeded = await queue.items
            if let self { self.items = seeded }
            for await event in stream {
                guard let self else { break }
                self.apply(event)
            }
        }
        eventTask.withLock { $0 = task }
    }

    deinit {
        eventTask.withLock { $0?.cancel() }
    }

    // MARK: Derived text (design 1c / MW-06x)

    var headerTitle: String {
        items.isEmpty ? "" : "Queue · \(items.count) \(items.count == 1 ? "file" : "files")"
    }

    var headerSubtitle: String {
        var parts: [String] = []
        let total = items.compactMap(\.duration).reduce(0, +)
        // Skip the duration clause entirely once it would round down to "0 min" — a near-silent
        // drop shouldn't claim "0 min of audio" in the header.
        if Int((total / 60).rounded()) > 0 { parts.append("\(Self.hoursMinutes(total)) of audio") }
        let done = items.filter { if case .done = $0.status { true } else { false } }.count
        let running = items.filter { if case .running = $0.status { true } else { false } }.count
        let failed = items.filter { if case .failed = $0.status { true } else { false } }.count
        if done > 0 { parts.append("\(done) done") }
        if running > 0 { parts.append("\(running) running") }
        if failed > 0 { parts.append("\(failed) need\(failed == 1 ? "s" : "") attention") }
        return parts.joined(separator: " · ")
    }

    var queuedCount: Int { items.filter { $0.status == .queued }.count }

    var transcribeButtonTitle: String {
        "Transcribe \(queuedCount) \(queuedCount == 1 ? "file" : "files") as \(settings.outputFormat.displayName)"
    }

    var canTranscribe: Bool { queuedCount > 0 && !needsModel }

    static func hoursMinutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let h = minutes / 60, m = minutes % 60
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        return "\(m) min"
    }

    // MARK: Actions

    func refreshModelState() async {
        needsModel = await modelStore.installedModels(role: .speech).isEmpty
    }

    func addFiles(_ urls: [URL]) async {
        var total: TimeInterval = 0
        for url in urls where SupportedAudio.isSupported(url) {
            total += (try? await durations.duration(of: url)) ?? 0
        }
        let hours = total / 3600
        if hours > Self.longAudioThresholdHours {
            confirmation = .longAudio(urls: urls, hours: hours)
            return
        }
        await queue.add(urls)
    }

    func confirmLongAudio() async {
        guard case .longAudio(let urls, _) = confirmation else { return }
        confirmation = nil
        await queue.add(urls)
    }

    func cancelConfirmation() { confirmation = nil }

    func transcribeAll() async {
        await refreshModelState()
        guard canTranscribe else { return }
        await queue.start()
    }

    func requestStop(_ item: QueueItem) async {
        // The caller's `item` can be stale (the view's own `items` render is throttled to once a
        // second); ask the queue for the live progress first and only fall back to the snapshot's
        // status if the row isn't running there any more (already finished/removed).
        var progress = await queue.progress(of: item.id)
        if progress == nil, case .running(let snapshotProgress) = item.status { progress = snapshotProgress }
        if let progress, progress > Self.stopConfirmationThreshold {
            confirmation = .stop(item, progress: progress)
        } else {
            await queue.cancel(id: item.id)
        }
    }

    func confirmStop() async {
        guard case .stop(let item, _) = confirmation else { return }
        confirmation = nil
        await queue.cancel(id: item.id)
    }

    func remove(_ item: QueueItem) async { await queue.remove(id: item.id) }

    func retry(_ item: QueueItem) async {
        await queue.retry(id: item.id)
        await refreshModelState()
        guard !needsModel else { return }
        await queue.start()
    }

    func open(_ item: QueueItem) {
        guard case .done(let document) = item.status else { return }
        selected = ExportedResult(item: item, document: document, url: exports.url(for: item.id))
    }

    func closeResult() { selected = nil }
    func exported(for item: QueueItem) -> URL? { exports.url(for: item.id) }
    func exportError(for item: QueueItem) -> String? { exports.error(for: item.id) }

    /// "about 3 min left" for a running row, throttled to one update per second (design 3d).
    func etaText(for item: QueueItem) -> String? {
        guard let seconds = etaSeconds[item.id] else { return nil }
        if seconds < 60 { return "about \(Int(seconds.rounded())) s left" }
        return "about \(Int((seconds / 60).rounded())) min left"
    }

    static func estimatedMinutes(forHours hours: Double) -> Int {
        Int((hours * 60 * estimatedRealTimeFactor).rounded(.up))
    }

    /// "Preparing…" below 5 % (the engine hasn't reported real progress yet), else "72 %" (design
    /// I5) — the running row's progress text.
    static func progressText(for progress: Double) -> String {
        progress < 0.05 ? "Preparing…" : "\(Int((progress * 100).rounded()))%"
    }

    /// The MW-06x copy for a failed row. `.decodeFailed`/`.engineFailed`/`.noModelInstalled` read as
    /// transient — retrying may help; `.unsupportedType` never will, so its row offers no Retry
    /// (see `canRetryFailure`). `.cancelled` is listed for exhaustiveness only: the queue reports a
    /// stopped job as `QueueItem.Status.cancelled`, never wrapped in `.failed`.
    static func failureMessage(_ error: FileTranscriptionError) -> String {
        switch error {
        case .decodeFailed: "Couldn’t decode this file — it may be incomplete or corrupt."
        case .unsupportedType: "Not an audio or video file. Supported: MP3, WAV, M4A, AAC, FLAC, MP4, MOV."
        case .noModelInstalled: "No speech model installed."
        case .engineFailed: "Transcription failed. You can try again."
        case .cancelled: "Stopped before finishing."
        }
    }

    /// Whether the failed row's MW-06x actions include Retry (vs. Remove only).
    static func canRetryFailure(_ error: FileTranscriptionError) -> Bool {
        if case .unsupportedType = error { return false }
        return true
    }

    /// Whether the badge should read as "this file was never eligible" (orange) rather than "the
    /// engine tried and failed" (red) — same distinction `canRetryFailure` draws, kept as its own
    /// named predicate so a row's badge color doesn't have to be inferred from Retry availability.
    static func isUnsupportedFailure(_ error: FileTranscriptionError) -> Bool {
        if case .unsupportedType = error { return true }
        return false
    }

    // MARK: Alert copy (design MW-06c stop confirmation, 3e long-audio confirmation)

    static func stopAlertTitle(for item: QueueItem) -> String {
        "Stop transcribing “\(item.url.lastPathComponent)”?"
    }

    static func stopAlertMessage(progress: Double) -> String {
        "It’s \(Int((progress * 100).rounded()))% done. The partial transcript will be discarded and the file stays in the queue."
    }

    static func longAudioAlertTitle(hours: Double) -> String {
        // A whole number of hours reads as "5 h", not the misleadingly-precise "5.0 h" — anything
        // else keeps the one decimal place (M3).
        let hoursText = hours.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(hours)) : String(format: "%.1f", hours)
        return "Transcribe \(hoursText) h of audio?"
    }

    static func longAudioAlertMessage(hours: Double) -> String {
        "About \(estimatedMinutes(forHours: hours)) min on this Mac."
    }

    // MARK: Events

    private func apply(_ event: FileQueueEvent) {
        switch event {
        case .added(let item):
            // The view model seeds `items` from `queue.items` *and* subscribes before that read
            // completes suspending; an `.added` published in the gap between subscribing and the
            // seed read would otherwise land in both the seed and the stream, duplicating the row.
            guard !items.contains(where: { $0.id == item.id }) else { return }
            items.append(item)
        case .changed(let item):
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            if case .running(let progress) = item.status {
                let timestamp = now()   // one read per event — record and the throttle gate must agree on "now"
                var estimator = estimators[item.id] ?? ETAEstimator()
                estimator.record(progress: progress, at: timestamp.timeIntervalSince1970)
                estimators[item.id] = estimator
                let last = lastRender[item.id] ?? .distantPast
                guard timestamp.timeIntervalSince(last) >= Self.uiRefreshInterval || progress >= 1 else { return }
                lastRender[item.id] = timestamp
                etaSeconds[item.id] = estimator.secondsRemaining
            } else {
                estimators[item.id] = nil
                etaSeconds[item.id] = nil
                lastRender[item.id] = nil
            }
            items[index] = item
        case .removed(let id):
            items.removeAll { $0.id == id }
        case .finished(let item):
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        case .idle:
            break
        }
    }
}
