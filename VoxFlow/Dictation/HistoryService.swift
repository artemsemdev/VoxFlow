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
    /// The shared `VoxFlowDatabase` behind `store` — `nil` until the first open resolves, and again
    /// whenever an open/reopen fails (mirrors `store`'s nil-ness: dictionary/snippets/style-override
    /// content lives on the same connection, so there is nothing for `ContentService` to use either).
    /// `ContentService` builds its three stores from this rather than opening a second connection.
    private(set) var database: VoxFlowDatabase?
    private(set) var status: Status = .disabled(reason: HistoryService.notOpenedYetReason)
    let storeBox = HistoryStoreBox()

    private let url: URL
    private let settings: DictationSettings
    private let keyProvider: @Sendable () -> any HistoryKeyProviding
    private let clock: any MonotonicClock
    private var retention: RetentionRunner?
    /// The in-flight (or most recently finished) open/reopen — every public accessor awaits this
    /// first, so a call made right after `init`/`reopen()` sees the resulting store rather than
    /// racing the detached open.
    private var openTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "dev.artemsem.voxflow", category: "history-service")

    init(url: URL, settings: DictationSettings, keyProvider: @escaping @Sendable () -> any HistoryKeyProviding, clock: any MonotonicClock) {
        self.url = url
        self.settings = settings
        self.keyProvider = keyProvider
        self.clock = clock
        // Deliberately no `reopen()` here: opening touches the Keychain (history key), and every
        // ad-hoc rebuild is a new code identity to macOS, so an open at construction would prompt on
        // every launch of the test host too (#143). The store opens on first use instead; Task 5's
        // launch wiring calls `ready()` once at launch when not running under XCTest.
    }

    /// Starts the first open if nothing has opened yet. Every accessor calls this before awaiting
    /// `openTask`, so the Keychain is only touched once history is actually used.
    private func ensureOpened() {
        guard openTask == nil else { return }
        openTask = Task { await self.performOpen() }
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
        openTask = Task {
            _ = await previous.value
            await self.performOpen()
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
    }

    func deleteAll() async {
        ensureOpened()
        await openTask?.value
        guard let store else { return }
        let log = Self.log
        await Task.detached(priority: .userInitiated) {
            do { try store.deleteAll() } catch { log.error("history deleteAll failed: \(String(describing: error))") }
        }.value
    }

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
                                   language: record.language, duration: record.duration, createdAt: record.createdAt)
        let log = Self.log
        return await Task.detached(priority: .userInitiated) {
            do { return try store.insert(draft) }
            catch { log.error("history reinsert failed: \(String(describing: error))"); return nil }
        }.value
    }

    private func performOpen() async {
        if let retention {
            await retention.stop()
            self.retention = nil
        }
        let url = self.url
        let useKey = settings.encryptHistory
        let makeKeyProvider = keyProvider
        do {
            let opened = try await Task.detached(priority: .userInitiated) { () throws -> (VoxFlowDatabase, DictationStore) in
                let database = try VoxFlowDatabase(url: url)
                let store = try DictationStore(database: database, keyProvider: useKey ? makeKeyProvider() : nil)
                return (database, store)
            }.value
            let (newDatabase, newStore) = opened
            store = newStore
            database = newDatabase
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
            database = nil
            storeBox.set(nil)
            status = .disabled(reason: "history key lost")
            Self.log.error("history key lost — history disabled")
        } catch {
            store = nil
            database = nil
            storeBox.set(nil)
            status = .disabled(reason: String(describing: error))
            Self.log.error("history store unavailable, history disabled: \(String(describing: error))")
        }
    }
}
