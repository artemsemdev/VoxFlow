import Foundation
import Synchronization

/// Selected input files remain readable for duration checks, queued work and retries this session.
/// Only successful security-scope acquisitions need a matching release. No bookmarks or paths persist.
final class FileInputAccess: Sendable {
    private let urls = Mutex<Set<URL>>([])
    private let start: @Sendable (URL) -> Bool
    private let stop: @Sendable (URL) -> Void

    init(start: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stop: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.start = start; self.stop = stop
    }

    func retain(_ selected: [URL]) {
        urls.withLock { active in
            for url in selected where !active.contains(url) {
                if start(url) { active.insert(url) }
            }
        }
    }

    deinit { urls.withLock { active in active.forEach(stop) } }
}
