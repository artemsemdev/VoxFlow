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

    private(set) var store: DictationStore?
    private(set) var status: Status = .disabled(reason: "not opened yet")
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
        reopen()
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
        let previous = openTask
        openTask = Task {
            _ = await previous?.value
            await self.performOpen()
        }
    }

    /// Awaits the current open/reopen chain without doing anything else — for callers (like
    /// `HistoryWriter`) that must not read `storeBox` before the first open (or a still-in-flight
    /// reopen) has resolved.
    func ready() async {
        await openTask?.value
    }

    func fetch(limit: Int) async -> [DictationRecord] {
        await openTask?.value
        guard let store else { return [] }
        return await Task.detached(priority: .userInitiated) { (try? store.fetch(limit: limit)) ?? [] }.value
    }

    func search(_ query: String) async -> [DictationRecord] {
        await openTask?.value
        guard let store else { return [] }
        return await Task.detached(priority: .userInitiated) { (try? store.search(query)) ?? [] }.value
    }

    func delete(id: Int64) async {
        await openTask?.value
        guard let store else { return }
        await Task.detached(priority: .userInitiated) { try? store.delete(id: id) }.value
    }

    func deleteAll() async {
        await openTask?.value
        guard let store else { return }
        await Task.detached(priority: .userInitiated) { try? store.deleteAll() }.value
    }

    func count() async -> Int {
        await openTask?.value
        guard let store else { return 0 }
        return await Task.detached(priority: .userInitiated) { (try? store.count()) ?? 0 }.value
    }

    /// Undo support: re-inserts a (typically just-deleted) record, preserving its original
    /// `createdAt` rather than stamping it with "now".
    @discardableResult
    func reinsert(_ record: DictationRecord) async -> DictationRecord? {
        await openTask?.value
        guard let store else { return nil }
        let draft = DictationDraft(text: record.text, rawText: record.rawText, appName: record.appName, style: record.style,
                                   language: record.language, duration: record.duration, createdAt: record.createdAt)
        return await Task.detached(priority: .userInitiated) { try? store.insert(draft) }.value
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
            let newStore = try await Task.detached(priority: .userInitiated) {
                try DictationStore(databaseURL: url, keyProvider: useKey ? makeKeyProvider() : nil)
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
            Self.log.error("history key lost — history disabled")
        } catch {
            store = nil
            storeBox.set(nil)
            status = .disabled(reason: String(describing: error))
            Self.log.error("history store unavailable, history disabled: \(String(describing: error))")
        }
    }
}
