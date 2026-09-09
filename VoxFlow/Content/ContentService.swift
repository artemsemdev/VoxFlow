import Foundation
import os
import Synchronization
import VoxFlowCore
import VoxFlowStorage
import VoxFlowStyling

/// Generic `Sendable` snapshot box — same shape as `HistoryStoreBox`/`DictationSettingsBox`, just
/// parameterized once instead of three near-identical wrapper types for the vocabulary/snippets/
/// style-override snapshots `StyledTranscriber` reads off the main actor.
final class SnapshotBox<Value: Sendable>: Sendable {
    private let box: Mutex<Value>
    init(_ initial: Value) { box = Mutex(initial) }
    var current: Value { box.withLock { $0 } }
    func set(_ value: Value) { box.withLock { $0 = value } }
}

/// Sendable pipe from `StyledTranscriber` (running off the main actor) into
/// `ContentService.noteUses` — same weak-attach pattern as `AppServices`' `DictationLevelSink`,
/// needed because `ContentService` itself isn't `Sendable` (it's `@MainActor`).
final class ContentUsesSink: Sendable {
    private struct WeakBox { weak var service: ContentService? }
    private let box = Mutex(WeakBox(service: nil))
    func attach(_ service: ContentService) { box.withLock { $0.service = service } }
    func note(text: String, snippets: [String]) {
        Task { @MainActor in
            guard let service = self.box.withLock({ $0.service }) else { return }
            await service.noteUses(text: text, snippets: snippets)
        }
    }
}

/// What `StyledTranscriber` reads off the main actor: the three content snapshots plus the
/// fire-and-forget hook that bumps dictionary/snippet usage counters after a dictation.
struct ContentSnapshots: Sendable {
    let vocabularyBox: SnapshotBox<[String]>
    let snippetsBox: SnapshotBox<[SnippetRule]>
    let overridesBox: SnapshotBox<[String: TextStyle]>
    let noteUses: @Sendable (String, [String]) -> Void
}

/// Owns the `DictionaryStore`/`SnippetStore`/`StyleOverrideStore` built on `HistoryService`'s shared
/// `VoxFlowDatabase` — Dictionary/Snippets/Styles page content, plus the snapshot boxes
/// `StyledTranscriber` reads off the main actor. Every store operation is blocking SQLite I/O, so
/// each runs on a detached task, same pattern as `HistoryService`.
///
/// When the database never became available (history storage failed to open this launch), every
/// operation below is a no-op returning an empty/`nil` result rather than throwing — logged once,
/// not on every call. When the database *is* available, real domain errors (e.g. a duplicate word)
/// still throw, so a future Dictionary/Snippets view model can surface validation as usual.
@Observable @MainActor
final class ContentService {
    enum Status: Equatable { case unavailable, ready }

    static let vocabularyLimit = 64

    private(set) var status: Status = .unavailable
    private let history: HistoryService
    private var dictionaryStore: DictionaryStore?
    private var snippetStore: SnippetStore?
    private var overrideStore: StyleOverrideStore?
    private var openTask: Task<Void, Never>?
    private var loggedUnavailable = false

    let vocabularyBox = SnapshotBox<[String]>([])
    let snippetsBox = SnapshotBox<[SnippetRule]>([])
    let overridesBox = SnapshotBox<[String: TextStyle]>([:])

    private static let log = Logger(subsystem: "dev.artemsem.voxflow", category: "content-service")

    init(history: HistoryService) {
        self.history = history
    }

    /// Starts opening (awaiting `history.ready()`, then building the three stores from
    /// `history.database`) if nothing has started yet, then awaits that open. Every wrapper below
    /// calls this first, mirroring `HistoryService.ensureOpened()`/`ready()`.
    func ready() async {
        if openTask == nil {
            openTask = Task { await self.open() }
        }
        await openTask?.value
    }

    private func open() async {
        await history.ready()
        guard let database = history.database else {
            status = .unavailable
            if !loggedUnavailable {
                Self.log.error("content service: no database available — dictionary/snippets/style overrides disabled")
                loggedUnavailable = true
            }
            return
        }
        dictionaryStore = DictionaryStore(database: database)
        snippetStore = SnippetStore(database: database)
        overrideStore = StyleOverrideStore(database: database)
        status = .ready
        await refreshVocabulary()
        await refreshSnippets()
        await refreshOverrides()
    }

    var dictionary: DictionaryAPI { DictionaryAPI(service: self) }
    var snippets: SnippetsAPI { SnippetsAPI(service: self) }
    var overrides: OverridesAPI { OverridesAPI(service: self) }

    /// A `ContentUsesSink` attached to this instance, for `AppServices` to hand to `StyledTranscriber`.
    func makeUsesSink() -> ContentUsesSink {
        let sink = ContentUsesSink()
        sink.attach(self)
        return sink
    }

    /// Bumps dictionary uses for every entry (single word or multi-word phrase, I3) matched inside
    /// `text`, and snippet uses for each trigger in `snippets` — fired by `StyledTranscriber` after
    /// every dictation (ruling 5 / ruling 4). Runs the writes off the main actor, then refreshes the
    /// boxes. `text` is the styled (not snippet-expanded) text, so a dictionary word appearing only
    /// inside a snippet's *body* is never counted as dictated (M2).
    func noteUses(text: String, snippets: [String]) async {
        await ready()
        guard status == .ready, let dictionaryStore, let snippetStore else { return }
        let log = Self.log
        if !text.isEmpty {
            await Task.detached(priority: .utility) {
                do { try dictionaryStore.incrementUses(inText: text) }
                catch { log.error("dictionary incrementUses failed: \(String(describing: error))") }
            }.value
        }
        for trigger in snippets {
            await Task.detached(priority: .utility) {
                do {
                    if let snippet = try snippetStore.find(trigger: trigger) {
                        try snippetStore.incrementUses(id: snippet.id)
                    }
                } catch { log.error("snippet incrementUses failed: \(String(describing: error))") }
            }.value
        }
        await refreshVocabulary()
        await refreshSnippets()
    }

    fileprivate func refreshVocabulary() async {
        guard let dictionaryStore else { vocabularyBox.set([]); return }
        let limit = Self.vocabularyLimit
        let words = await Task.detached(priority: .utility) { (try? dictionaryStore.vocabulary(limit: limit)) ?? [] }.value
        vocabularyBox.set(words)
    }

    fileprivate func refreshSnippets() async {
        guard let snippetStore else { snippetsBox.set([]); return }
        let all = await Task.detached(priority: .utility) { (try? snippetStore.all()) ?? [] }.value
        snippetsBox.set(all.map { SnippetRule(trigger: $0.trigger, body: $0.body, onlyInBundleID: $0.onlyInBundleID) })
    }

    fileprivate func refreshOverrides() async {
        guard let overrideStore else { overridesBox.set([:]); return }
        let all = await Task.detached(priority: .utility) { (try? overrideStore.all()) ?? [] }.value
        overridesBox.set(Dictionary(uniqueKeysWithValues: all.map { ($0.bundleID, $0.style) }))
    }

    // MARK: - Dictionary

    @MainActor
    struct DictionaryAPI {
        let service: ContentService

        func all() async -> [DictionaryEntry] {
            await service.ready()
            guard let store = service.dictionaryStore else { return [] }
            return await Task.detached(priority: .utility) { (try? store.all()) ?? [] }.value
        }

        /// `nil` only when the database is unavailable; a duplicate word still throws
        /// `StorageError.duplicate(existingID:)` as usual.
        @discardableResult
        func insert(word: String, soundsLike: String?, type: DictionaryEntryType, fixTyping: Bool, source: String = "user") async throws -> DictionaryEntry? {
            await service.ready()
            guard let store = service.dictionaryStore else { return nil }
            let entry = try await Task.detached(priority: .utility) {
                try store.insert(word: word, soundsLike: soundsLike, type: type, fixTyping: fixTyping, source: source)
            }.value
            await service.refreshVocabulary()
            return entry
        }

        func update(_ entry: DictionaryEntry) async throws {
            await service.ready()
            guard let store = service.dictionaryStore else { return }
            try await Task.detached(priority: .utility) { try store.update(entry) }.value
            await service.refreshVocabulary()
        }

        func delete(id: Int64) async throws {
            await service.ready()
            guard let store = service.dictionaryStore else { return }
            try await Task.detached(priority: .utility) { try store.delete(id: id) }.value
            await service.refreshVocabulary()
        }

        func find(word: String) async -> DictionaryEntry? {
            await service.ready()
            guard let store = service.dictionaryStore else { return nil }
            return await Task.detached(priority: .utility) { (try? store.find(word: word)) ?? nil }.value
        }

        func removeAll(source: String) async throws {
            await service.ready()
            guard let store = service.dictionaryStore else { return }
            try await Task.detached(priority: .utility) { try store.removeAll(source: source) }.value
            await service.refreshVocabulary()
        }

        /// Most-used first, capped at `ContentService.vocabularyLimit` (64) — the store applies the limit.
        func vocabulary() async -> [String] {
            await service.ready()
            guard let store = service.dictionaryStore else { return [] }
            let limit = ContentService.vocabularyLimit
            return await Task.detached(priority: .utility) { (try? store.vocabulary(limit: limit)) ?? [] }.value
        }
    }

    // MARK: - Snippets

    @MainActor
    struct SnippetsAPI {
        let service: ContentService

        func all() async -> [Snippet] {
            await service.ready()
            guard let store = service.snippetStore else { return [] }
            return await Task.detached(priority: .utility) { (try? store.all()) ?? [] }.value
        }

        /// `nil` only when the database is unavailable; a duplicate trigger still throws
        /// `StorageError.duplicate(existingID:)` as usual.
        @discardableResult
        func insert(trigger: String, body: String, onlyIn: (bundleID: String, appName: String)? = nil) async throws -> Snippet? {
            await service.ready()
            guard let store = service.snippetStore else { return nil }
            let snippet = try await Task.detached(priority: .utility) { try store.insert(trigger: trigger, body: body, onlyIn: onlyIn) }.value
            await service.refreshSnippets()
            return snippet
        }

        func update(_ snippet: Snippet) async throws {
            await service.ready()
            guard let store = service.snippetStore else { return }
            try await Task.detached(priority: .utility) { try store.update(snippet) }.value
            await service.refreshSnippets()
        }

        func delete(id: Int64) async throws {
            await service.ready()
            guard let store = service.snippetStore else { return }
            try await Task.detached(priority: .utility) { try store.delete(id: id) }.value
            await service.refreshSnippets()
        }

        func find(trigger: String) async -> Snippet? {
            await service.ready()
            guard let store = service.snippetStore else { return nil }
            return await Task.detached(priority: .utility) { (try? store.find(trigger: trigger)) ?? nil }.value
        }
    }

    // MARK: - Style overrides

    @MainActor
    struct OverridesAPI {
        let service: ContentService

        func all() async -> [StyleOverride] {
            await service.ready()
            guard let store = service.overrideStore else { return [] }
            return await Task.detached(priority: .utility) { (try? store.all()) ?? [] }.value
        }

        func set(bundleID: String, appName: String, style: TextStyle) async throws {
            await service.ready()
            guard let store = service.overrideStore else { return }
            try await Task.detached(priority: .utility) { try store.set(bundleID: bundleID, appName: appName, style: style) }.value
            await service.refreshOverrides()
        }

        func remove(bundleID: String) async throws {
            await service.ready()
            guard let store = service.overrideStore else { return }
            try await Task.detached(priority: .utility) { try store.remove(bundleID: bundleID) }.value
            await service.refreshOverrides()
        }

        func style(for bundleID: String) async -> TextStyle? {
            await service.ready()
            guard let store = service.overrideStore else { return nil }
            return await Task.detached(priority: .utility) { (try? store.style(for: bundleID)) ?? nil }.value
        }
    }
}
