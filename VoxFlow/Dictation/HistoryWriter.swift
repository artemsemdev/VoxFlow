import Foundation
import os
import VoxFlowDictation
import VoxFlowStorage

/// Persists a finished dictation to history, respecting the "Keep history" toggle (design ST-05).
/// Whether a *given* capture should skip this entirely (onboarding's Try It, a History scratchpad) is
/// no longer this type's concern — `DictationController`'s `ephemeral:` closure decides that once per
/// capture and simply never invokes the `onSave` handler this writer is wired to (I-1/I-2/I-3).
struct HistoryWriter: Sendable {
    /// Read at save time (not captured once) so a `HistoryService.reopen()` — e.g. toggling
    /// "Encrypt history at rest" — takes effect on the very next save, not only after a relaunch.
    let storeBox: HistoryStoreBox
    let settings: DictationSettingsBox
    let now: @Sendable () -> Date
    /// Awaited before `storeBox` is read (when history is being saved at all — see `save`): without
    /// this, a dictation that finishes before `HistoryService`'s first (or a still-in-flight reopen's)
    /// open resolves would find `storeBox.current == nil` and silently drop the entry. Defaulted to
    /// a no-op so every existing call site (`HistoryWriter(storeBox:settings:now:)`) keeps compiling
    /// unchanged; `AppServices` passes `{ await historyService.ready() }`.
    var ready: @Sendable () async -> Void = {}
    private static let log = Logger(subsystem: "dev.artemsem.voxflow", category: "history")

    static func draft(from result: DictationResult, appName: String?, now: Date) -> DictationDraft {
        DictationDraft(text: result.text, rawText: result.rawText, appName: appName, style: nil,
                       language: result.language?.code, duration: result.duration, createdAt: now)
    }

    /// No-op when history is off or there's no store (Privacy toggle / storage unavailable). The
    /// insert itself is blocking SQLite I/O, so it runs on a detached task off the caller's actor.
    func save(_ result: DictationResult, appName: String?) async {
        guard settings.current.keepHistory else { return }
        await ready()
        guard let store = storeBox.current else { return }
        let draft = Self.draft(from: result, appName: appName, now: now())
        await Task.detached(priority: .utility) {
            do { _ = try store.insert(draft) } catch { Self.log.error("history insert failed: \(String(describing: error))") }
        }.value
    }
}
