import Foundation
import os
import Synchronization
import VoxFlowCore
import VoxFlowStorage

/// Sendable box around the current `DictationStore`, read by `HistoryWriter` at save time —
/// mirrors `DictationSettingsBox`'s pattern for crossing from a `@MainActor`-owned value into a
/// `Sendable` context that isn't itself the main actor.
final class HistoryStoreBox: Sendable {
    private let box: Mutex<DictationStore?>
    init(_ initial: DictationStore? = nil) { box = Mutex(initial) }
    var current: DictationStore? { box.withLock { $0 } }
    func set(_ store: DictationStore?) { box.withLock { $0 = store } }
}

/// The single owner of the `DictationStore`: opens/reopens it (per the "Encrypt history at rest"
/// toggle), runs its `RetentionRunner`, and is the one place History reads/writes go through.
/// Every store operation is blocking SQLite I/O, so each runs on a detached task off the main actor.
@Observable @MainActor
final class HistoryService {
    enum Status: Equatable {
        case ready
        case disabled(reason: String)
    }

    /// `status`'s reason before the first open ever runs — not a real failure (I-4's
    /// `HistoryViewModel.emptyState`/`PrivacyViewModel` both skip surfacing this one specifically),
    /// just "no one has touched history yet this launch".
    static let notOpenedYetReason = "not opened yet"

    private(set) var store: DictationStore?
    /// The shared `VoxFlowDatabase` behind `store` — `nil` until the database *file* has opened, and
    /// again only if opening that file itself fails. Deliberately independent of `store`/`status`:
    /// dictionary/snippets/style overrides live on the same connection but need neither the history
    /// key nor a working `DictationStore` (a `.keyLost`/other `DictationStore` failure disables
    /// history alone, via `store`/`status`, and must not take `database` down with it — otherwise
    /// `ContentService` dies whenever history does, for a table that isn't even encrypted). Once
    /// non-nil, `reopen()` reuses this same instance rather than reopening the file again.
    /// `ContentService` builds its three stores from this rather than opening a second connection.
    private(set) var database: VoxFlowDatabase?
    private(set) var status: Status = .disabled(reason: HistoryService.notOpenedYetReason)
    let storeBox = HistoryStoreBox()
    /// Fired after any write that changes what's on disk — `delete`/`deleteAll`/`reinsert` below call
    /// it directly; `HistoryWriter`'s own insert path (which saves through `storeBox` rather than
    /// this service) calls it too, via its `onSaved` hook wired in `AppServices.live()`
    /// (`HistorySavedSink`, review C1). `StatsService.refresh()` is the intended subscriber so
    /// Home's/the menu bar's numbers stay live after every dictation, not just after a History
    /// delete/undo.
    var onChange: (() -> Void)?

    private let url: URL
    private let settings: DictationSettings
    private let keyProvider: @Sendable () -> any HistoryKeyProviding
    private let clock: any MonotonicClock
    private let openDatabase: @Sendable (URL) throws -> VoxFlowDatabase
    private var retention: RetentionRunner?
    /// The in-flight (or most recently finished) open/reopen — every public accessor awaits this
    /// first, so a call made right after `init`/`reopen()` sees the resulting store rather than
    /// racing the detached open.
    private var openTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "dev.artemsem.voxflow", category: "history-service")

    init(url: URL, settings: DictationSettings, keyProvider: @escaping @Sendable () -> any HistoryKeyProviding,
         clock: any MonotonicClock,
         openDatabase: @escaping @Sendable (URL) throws -> VoxFlowDatabase = { try VoxFlowDatabase(url: $0) }) {
        self.url = url
        self.settings = settings
        self.keyProvider = keyProvider
        self.clock = clock
        self.openDatabase = openDatabase
        // Deliberately no `reopen()` here: opening touches the Keychain (history key), and every
        // ad-hoc rebuild is a new code identity to macOS, so an open at construction would prompt on
        // every launch of the test host too (#143). The store opens on first use instead; Task 5's
        // launch wiring calls `ready()` once at launch when not running under XCTest.
    }

    /// Starts the first open if nothing has opened yet. Every accessor calls this before awaiting
    /// `openTask`, so the Keychain is only touched once history is actually used.
    private func ensureOpened() {
        guard openTask == nil else { return }
        openTask = Task { [weak self] in await self?.performOpen() }
    }

    /// Rebuilds the store with/without the key provider per `settings.encryptHistory`, and restarts
    /// retention. Fire-and-forget by design — callers (including `init`) don't await this; every
    /// public accessor below awaits the resulting `openTask` before touching `store`.
    ///
    /// Chains onto the previous `openTask` rather than discarding it: two `reopen()` calls issued
    /// back to back (e.g. `encryptHistory` and `retentionDays` changing together) would otherwise run
    /// their `performOpen()`s concurrently, race to write `store`/`storeBox`/`status`/`retention`, and
    /// could leak whichever `RetentionRunner` loses that race (never `stop()`-ed). Chaining guarantees
    /// opens run strictly one at a time in call order, so the last `reopen()` always wins and every
    /// runner but the current one is `stop()`-ed before the next is created.
    func reopen() {
        // Settings changed before the first open: nothing to rebuild — the eventual first open
        // reads the current settings anyway, and forcing an open here would touch the Keychain
        // just because a toggle moved.
        guard let previous = openTask else { return }
        openTask = Task { [weak self] in
            _ = await previous.value
            await self?.performOpen()
        }
    }

    /// Awaits the current open/reopen chain without doing anything else — for callers (like
    /// `HistoryWriter`) that must not read `storeBox` before the first open (or a still-in-flight
    /// reopen) has resolved.
    func ready() async {
        ensureOpened()
        await openTask?.value
    }

    func fetch(limit: Int) async -> [DictationRecord] {
        ensureOpened()
        await openTask?.value
        guard let store else { return [] }
        return await Task.detached(priority: .userInitiated) { (try? store.fetch(limit: limit)) ?? [] }.value
    }

    func search(_ query: String) async -> [DictationRecord] {
        ensureOpened()
        await openTask?.value
        guard let store else { return [] }
        return await Task.detached(priority: .userInitiated) { (try? store.search(query)) ?? [] }.value
    }

    /// M-9: logged (not just `try?`-swallowed) — a failed delete leaves the row gone from the UI but
    /// still on disk until the next refresh, and that's worth a trace even though it's not surfaced
    /// to the user.
    func delete(id: Int64) async {
        ensureOpened()
        await openTask?.value
        guard let store else { return }
        let log = Self.log   // `Logger` is a `Sendable` value type — read here (MainActor) for the detached task below.
        await Task.detached(priority: .userInitiated) {
            do { try store.delete(id: id) } catch { log.error("history delete failed: \(String(describing: error))") }
        }.value
        notifyChanged()
    }

    func deleteAll() async {
        ensureOpened()
        await openTask?.value
        guard let store else { return }
        let log = Self.log
        await Task.detached(priority: .userInitiated) {
            do { try store.deleteAll() } catch { log.error("history deleteAll failed: \(String(describing: error))") }
        }.value
        notifyChanged()
    }

    /// Re-style (MW-02s): replaces a stored row's text/style in place. Nil when the row no longer
    /// exists (same "on success" notify rule as `reinsert`, below).
    func updateStyled(id: Int64, text: String, style: String) async -> DictationRecord? {
        ensureOpened()
        await openTask?.value
        guard let store else { return nil }
        let log = Self.log
        let updated: DictationRecord? = await Task.detached(priority: .userInitiated) { () -> DictationRecord? in
            do { return try store.updateStyled(id: id, text: text, style: style) }
            catch { log.error("history updateStyled failed: \(String(describing: error))"); return nil }
        }.value
        if updated != nil { notifyChanged() }
        return updated
    }

    /// Inline correction: notify Home/menu-bar statistics only after a successful persisted edit.
    func updateText(id: Int64, text: String) async -> DictationRecord? {
        ensureOpened()
        await openTask?.value
        guard let store else { return nil }
        let log = Self.log
        let updated: DictationRecord? = await Task.detached(priority: .userInitiated) {
            do { return try store.updateText(id: id, text: text) }
            catch { log.error("history updateText failed: \(String(describing: error))"); return nil }
        }.value
        if updated != nil { notifyChanged() }
        return updated
    }

    /// See `onChange`'s doc comment — called after every write that changes what's on disk.
    func notifyChanged() { onChange?() }

    func count() async -> Int {
        ensureOpened()
        await openTask?.value
        guard let store else { return 0 }
        return await Task.detached(priority: .userInitiated) { (try? store.count()) ?? 0 }.value
    }

    /// Undo support: re-inserts a (typically just-deleted) record, preserving its original
    /// `createdAt` rather than stamping it with "now".
    @discardableResult
    func reinsert(_ record: DictationRecord) async -> DictationRecord? {
        ensureOpened()
        await openTask?.value
        guard let store else { return nil }
        let draft = DictationDraft(text: record.text, rawText: record.rawText, appName: record.appName, style: record.style,
                                   language: record.language, duration: record.duration, createdAt: record.createdAt,
                                   annotations: record.annotations)
        let log = Self.log
        let inserted: DictationRecord? = await Task.detached(priority: .userInitiated) { () -> DictationRecord? in
            do { return try store.insert(draft) }
            catch { log.error("history reinsert failed: \(String(describing: error))"); return nil }
        }.value
        if inserted != nil { notifyChanged() }
        return inserted
    }

    private func performOpen() async {
        if let retention {
            await retention.stop()
            self.retention = nil
        }
        let url = self.url
        let useKey = settings.encryptHistory
        let makeKeyProvider = keyProvider

        // Step 1: open the database *file* — independent of the history key. Reuses `database` across
        // a `reopen()` (only the key/cipher choice or retention window changed, never `url`) instead
        // of reopening the file every time; only a fresh failure to open the file itself clears it.
        let openedDatabase: VoxFlowDatabase
        if let database {
            openedDatabase = database
        } else {
            do {
                let openDatabase = self.openDatabase
                openedDatabase = try await Task.detached(priority: .userInitiated) { try openDatabase(url) }.value
            } catch {
                store = nil
                database = nil
                storeBox.set(nil)
                status = .disabled(reason: String(describing: error))
                Self.log.error("history database unavailable, history and content disabled: \(String(describing: error))")
                return
            }
            database = openedDatabase
        }

        // Step 2: build the (possibly-encrypted) `DictationStore` on top of it. A failure here —
        // `.keyLost` included — disables history alone: `database` stays published so `ContentService`
        // (dictionary/snippets/style overrides, none of them encrypted) keeps working.
        do {
            let newStore = try await Task.detached(priority: .userInitiated) {
                try DictationStore(database: openedDatabase, keyProvider: useKey ? makeKeyProvider() : nil)
            }.value
            store = newStore
            storeBox.set(newStore)
            status = .ready
            // Captured once per open, not re-read per purge pass: a later `retentionDays` change
            // always flows through `onHistorySettingsChange` → `reopen()`, which rebuilds this
            // runner (and its policy closure) from scratch.
            let days = settings.retentionDays
            let runner = RetentionRunner(store: newStore, policy: { RetentionPolicy(days: days) }, now: Date.init, clock: clock)
            retention = runner
            Task { await runner.start() }
        } catch StorageError.keyLost {
            store = nil
            storeBox.set(nil)
            status = .disabled(reason: "history key lost")
            Self.log.error("history key lost — history disabled (content database stays open)")
        } catch {
            store = nil
            storeBox.set(nil)
            status = .disabled(reason: String(describing: error))
            Self.log.error("history store unavailable, history disabled (content database stays open): \(String(describing: error))")
        }
    }
}
