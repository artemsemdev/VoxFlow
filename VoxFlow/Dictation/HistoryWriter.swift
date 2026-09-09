import Foundation
import os
import VoxFlowDictation
import VoxFlowStorage

/// Persists a finished dictation to history, respecting the "Keep history" toggle (design ST-05).
struct HistoryWriter: Sendable {
    /// Read at save time (not captured once) so a `HistoryService.reopen()` — e.g. toggling
    /// "Encrypt history at rest" — takes effect on the very next save, not only after a relaunch.
    let storeBox: HistoryStoreBox
    let settings: DictationSettingsBox
    let now: @Sendable () -> Date
    private static let log = Logger(subsystem: "dev.artemsem.voxflow", category: "history")

    static func draft(from result: DictationResult, appName: String?, now: Date) -> DictationDraft {
        DictationDraft(text: result.text, rawText: result.rawText, appName: appName, style: nil,
                       language: result.language?.code, duration: result.duration, createdAt: now)
    }

    /// No-op when history is off or there's no store (Privacy toggle / storage unavailable). The
    /// insert itself is blocking SQLite I/O, so it runs on a detached task off the caller's actor.
    func save(_ result: DictationResult, appName: String?) async {
        guard settings.current.keepHistory, let store = storeBox.current else { return }
        let draft = Self.draft(from: result, appName: appName, now: now())
        await Task.detached(priority: .utility) {
            do { _ = try store.insert(draft) } catch { Self.log.error("history insert failed: \(String(describing: error))") }
        }.value
    }
}
