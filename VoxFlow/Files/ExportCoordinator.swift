import Foundation
import VoxFlowCore
import VoxFlowFiles
import Synchronization

/// Exports every finished transcript in the current format as soon as it finishes, whether or not the
/// Files page is open (design 2f "Saved to ~/Transcripts/…", MB-04 background completion).
@Observable @MainActor
final class ExportCoordinator {
    private(set) var exportedURLs: [UUID: URL] = [:]
    private(set) var exportErrors: [UUID: String] = [:]
    private var removedIDs: Set<UUID> = []
    private var exportWaiters: [(Set<UUID>, CheckedContinuation<Void, Never>)] = []

    /// Queue completion can precede this subscriber writing the final transcript.
    func waitForExports(of items: [QueueItem]) async -> Bool {
        let ids = Set(items.compactMap { item -> UUID? in
            if case .done = item.status { item.id } else { nil }
        })
        if !exportsFinished(ids) {
            await withCheckedContinuation { exportWaiters.append((ids, $0)) }
        }
        return ids.allSatisfy { removedIDs.contains($0) || exportedURLs[$0] != nil }
    }

    private func exportsFinished(_ ids: Set<UUID>) -> Bool {
        ids.allSatisfy { removedIDs.contains($0) || exportedURLs[$0] != nil || exportErrors[$0] != nil }
    }

    private func resumeExportWaiters() {
        exportWaiters.removeAll { ids, continuation in
            guard exportsFinished(ids) else { return false }
            continuation.resume()
            return true
        }
    }

    private let task = Mutex<Task<Void, Never>?>(nil)

    /// Fired after a successful export only — never on a failed one. MB-04 (review I2) subscribes
    /// to this instead of racing `FileQueue.finished` directly: the two were independent
    /// subscribers with no delivery-order guarantee, so a notification could post before the
    /// export had written anything, with a hard-coded folder and even after the export itself
    /// failed. This hook fires with the real written URL and the format actually used, exactly
    /// once, only once the file is genuinely on disk.
    var onExported: ((QueueItem, TranscriptDocument, URL, OutputFormat) -> Void)?

    init(queue: FileQueue, settings: FilesSettings, exporter: @escaping () -> TranscriptExporter) {
        let job = Task { [weak self] in
            let stream = await queue.subscribe()
            for await event in stream {
                guard let self else { break }
                self.apply(event, settings: settings, exporter: exporter)
            }
        }
        task.withLock { $0 = job }
    }

    deinit { task.withLock { $0?.cancel() } }

    func url(for id: UUID) -> URL? { exportedURLs[id] }
    func error(for id: UUID) -> String? { exportErrors[id] }

    private func apply(_ event: FileQueueEvent, settings: FilesSettings, exporter: () -> TranscriptExporter) {
        switch event {
        case .finished(let item):
            guard case .done(let document) = item.status else { return }
            defer { resumeExportWaiters() }
            do {
                let format = settings.outputFormat
                let url = try exporter().export(document, format: format, timestamps: settings.timestamps)
                exportedURLs[item.id] = url
                exportErrors[item.id] = nil
                onExported?(item, document, url, format)
            } catch {
                exportErrors[item.id] = error.localizedDescription
            }
        case .removed(let id):
            removedIDs.insert(id)
            defer { resumeExportWaiters() }
            exportedURLs[id] = nil
            exportErrors[id] = nil
        default:
            break
        }
    }
}
