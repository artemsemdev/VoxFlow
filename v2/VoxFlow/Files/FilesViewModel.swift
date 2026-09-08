import Foundation
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
    private(set) var exportedURLs: [UUID: URL] = [:]
    private(set) var exportErrors: [UUID: String] = [:]
    private(set) var etaSeconds: [UUID: TimeInterval] = [:]

    private let queue: FileQueue
    private let settings: FilesSettings
    private let modelStore: ModelStore
    private let durations: any AudioDurationProviding
    private let makeExporter: () -> TranscriptExporter
    private let now: () -> Date
    private var estimators: [UUID: ETAEstimator] = [:]
    private var lastRender: [UUID: Date] = [:]
    private var eventTask: Task<Void, Never>?

    init(queue: FileQueue, settings: FilesSettings, modelStore: ModelStore, durations: any AudioDurationProviding,
         exporter: @escaping () -> TranscriptExporter, now: @escaping () -> Date = { Date() }) {
        self.queue = queue
        self.settings = settings
        self.modelStore = modelStore
        self.durations = durations
        self.makeExporter = exporter
        self.now = now
        eventTask = Task { [weak self] in
            guard let self else { return }
            let stream = await queue.subscribe()
            self.items = await queue.items
            for await event in stream {
                guard !Task.isCancelled else { break }
                self.apply(event)
            }
        }
    }

    /// `deinit` runs off the main actor by default; every access this class makes happens on
    /// MainActor (the only place a `FilesViewModel` is ever created, used or released), so this
    /// assertion is safe — it lets deinit still cancel the event task instead of leaking it.
    deinit {
        MainActor.assumeIsolated { eventTask?.cancel() }
    }

    // MARK: Derived text (design 1c / MW-06x)

    var headerTitle: String {
        items.isEmpty ? "" : "Queue · \(items.count) \(items.count == 1 ? "file" : "files")"
    }

    var headerSubtitle: String {
        var parts: [String] = []
        let total = items.compactMap(\.duration).reduce(0, +)
        if total > 0 { parts.append("\(Self.hoursMinutes(total)) of audio") }
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
        if case .running(let progress) = item.status, progress > Self.stopConfirmationThreshold {
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
    func retry(_ item: QueueItem) async { await queue.retry(id: item.id); await queue.start() }

    func open(_ item: QueueItem) {
        guard case .done(let document) = item.status else { return }
        selected = ExportedResult(item: item, document: document, url: exportedURLs[item.id])
    }

    func closeResult() { selected = nil }
    func exported(for item: QueueItem) -> URL? { exportedURLs[item.id] }

    /// "about 3 min left" for a running row, throttled to one update per second (design 3d).
    func etaText(for item: QueueItem) -> String? {
        guard let seconds = etaSeconds[item.id] else { return nil }
        if seconds < 60 { return "about \(Int(seconds.rounded())) s left" }
        return "about \(Int((seconds / 60).rounded())) min left"
    }

    static func estimatedMinutes(forHours hours: Double) -> Int {
        Int((hours * 60 * estimatedRealTimeFactor).rounded(.up))
    }

    // MARK: Events

    private func apply(_ event: FileQueueEvent) {
        switch event {
        case .added(let item):
            items.append(item)
        case .changed(let item):
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            if case .running(let progress) = item.status {
                var estimator = estimators[item.id] ?? ETAEstimator()
                estimator.record(progress: progress, at: now().timeIntervalSince1970)
                estimators[item.id] = estimator
                let last = lastRender[item.id] ?? .distantPast
                guard now().timeIntervalSince(last) >= Self.uiRefreshInterval || progress >= 1 else { return }
                lastRender[item.id] = now()
                etaSeconds[item.id] = estimator.secondsRemaining
            } else {
                estimators[item.id] = nil
                etaSeconds[item.id] = nil
                lastRender[item.id] = nil
            }
            items[index] = item
        case .removed(let id):
            items.removeAll { $0.id == id }
            exportedURLs[id] = nil
            exportErrors[id] = nil
        case .finished(let item):
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
            if case .done(let document) = item.status {
                do {
                    exportedURLs[item.id] = try makeExporter().export(document, format: settings.outputFormat, timestamps: settings.timestamps)
                } catch {
                    exportErrors[item.id] = error.localizedDescription
                }
            }
        case .idle:
            break
        }
    }
}
