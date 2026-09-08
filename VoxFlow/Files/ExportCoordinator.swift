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
    private let task = Mutex<Task<Void, Never>?>(nil)

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
            do {
                exportedURLs[item.id] = try exporter().export(document, format: settings.outputFormat, timestamps: settings.timestamps)
                exportErrors[item.id] = nil
            } catch {
                exportErrors[item.id] = error.localizedDescription
            }
        case .removed(let id):
            exportedURLs[id] = nil
            exportErrors[id] = nil
        default:
            break
        }
    }
}
