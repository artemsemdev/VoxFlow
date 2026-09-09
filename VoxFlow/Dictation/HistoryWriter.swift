import Foundation
import os
import Synchronization
import VoxFlowDictation
import VoxFlowStorage

/// Sendable box for `HistoryWriter.suppressNext()` — `HistoryWriter` is a `struct`, and `Mutex` is
/// noncopyable, so the flag lives behind a class reference the same way `HistoryStoreBox` and
/// `DictationSettingsBox` box their own `Mutex`-guarded state.
final class HistorySuppressBox: Sendable {
    private let flag = Mutex(false)
    func set() { flag.withLock { $0 = true } }
    /// Reads and clears in one step so exactly one `save` is skipped per `set()`.
    func consume() -> Bool { flag.withLock { let was = $0; $0 = false; return was } }
}

/// Persists a finished dictation to history, respecting the "Keep history" toggle (design ST-05).
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
    /// Defaulted so every existing call site (`HistoryWriter(storeBox:settings:now:)`) keeps
    /// compiling unchanged; a caller that wants to suppress a save (onboarding's Try It, ONB-05)
    /// holds onto the same `HistoryWriter` value and calls `suppressNext()` on it.
    private let suppress = HistorySuppressBox()
    private static let log = Logger(subsystem: "dev.artemsem.voxflow", category: "history")

    static func draft(from result: DictationResult, appName: String?, now: Date) -> DictationDraft {
        DictationDraft(text: result.text, rawText: result.rawText, appName: appName, style: nil,
                       language: result.language?.code, duration: result.duration, createdAt: now)
    }

    /// Skips exactly the next `save` call (e.g. onboarding's Try It dictation, which shouldn't leave
    /// a real history entry) without disabling history for any dictation after that one.
    func suppressNext() { suppress.set() }

    /// No-op when history is off, there's no store (Privacy toggle / storage unavailable), or this
    /// save was just suppressed via `suppressNext()`. The insert itself is blocking SQLite I/O, so it
    /// runs on a detached task off the caller's actor.
    func save(_ result: DictationResult, appName: String?) async {
        if suppress.consume() { return }
        guard settings.current.keepHistory else { return }
        await ready()
        guard let store = storeBox.current else { return }
        let draft = Self.draft(from: result, appName: appName, now: now())
        await Task.detached(priority: .utility) {
            do { _ = try store.insert(draft) } catch { Self.log.error("history insert failed: \(String(describing: error))") }
        }.value
    }
}
