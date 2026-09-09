import CryptoKit
import Foundation
import Testing
import VoxFlowCore
import VoxFlowStorage
import VoxFlowStyling
import VoxFlowTestSupport
@testable import VoxFlow

private struct DummyKeyProvider: HistoryKeyProviding {
    func historyKey() throws -> HistoryKey { HistoryKey(key: SymmetricKey(size: .bits256), isNewlyCreated: false) }
}

@Suite("ContentService")
@MainActor
struct ContentServiceTests {
    /// Plaintext (no encryption) history over a temp file — `ContentService` only needs
    /// `history.database`, never the cipher, so this keeps the fixture simple.
    func makeContent(dir: TemporaryDirectory) -> ContentService {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        settings.retentionDays = 0
        settings.encryptHistory = false
        let history = HistoryService(url: dir.file("voxflow.sqlite"), settings: settings,
                                     keyProvider: { DummyKeyProvider() }, clock: FakeClock())
        return ContentService(history: history)
    }

    // MARK: - Dictionary

    @Test("dictionary CRUD via the async wrappers, and vocabularyBox refreshes after insert")
    func dictionaryCRUD() async throws {
        let content = makeContent(dir: TemporaryDirectory())
        await content.ready()
        #expect(content.status == .ready)

        let entry = try await content.dictionary.insert(word: "Kubernetes", soundsLike: "koo-ber-net-eez", type: .term, fixTyping: false)
        #expect(entry?.word == "Kubernetes")
        #expect(content.vocabularyBox.current.contains("Kubernetes"))

        var all = await content.dictionary.all()
        #expect(all.map(\.word) == ["Kubernetes"])

        var updated = try #require(all.first)
        updated.soundsLike = "koo-burr-net-eez"
        try await content.dictionary.update(updated)
        let found = await content.dictionary.find(word: "kubernetes")
        #expect(found?.soundsLike == "koo-burr-net-eez")

        try await content.dictionary.delete(id: updated.id)
        all = await content.dictionary.all()
        #expect(all.isEmpty)
        #expect(content.vocabularyBox.current.isEmpty)
    }

    @Test("duplicate insert throws StorageError.duplicate through the wrapper")
    func dictionaryDuplicateThrows() async throws {
        let content = makeContent(dir: TemporaryDirectory())
        _ = try await content.dictionary.insert(word: "Kubernetes", soundsLike: nil, type: .term, fixTyping: false)
        await #expect(throws: StorageError.self) {
            _ = try await content.dictionary.insert(word: "kubernetes", soundsLike: nil, type: .term, fixTyping: false)
        }
    }

    @Test("removeAll(source:) keeps user entries")
    func removeAllKeepsUserEntries() async throws {
        let content = makeContent(dir: TemporaryDirectory())
        _ = try await content.dictionary.insert(word: "Priya", soundsLike: nil, type: .name, fixTyping: false, source: "contacts")
        _ = try await content.dictionary.insert(word: "Kubernetes", soundsLike: nil, type: .term, fixTyping: false, source: "user")
        try await content.dictionary.removeAll(source: "contacts")
        let all = await content.dictionary.all()
        #expect(all.map(\.word) == ["Kubernetes"])
    }

    @Test("vocabulary is capped at 64 words")
    func vocabularyLimitedTo64() async throws {
        let content = makeContent(dir: TemporaryDirectory())
        for i in 0..<70 {
            _ = try await content.dictionary.insert(word: "word\(i)", soundsLike: nil, type: .term, fixTyping: false)
        }
        let vocabulary = await content.dictionary.vocabulary()
        #expect(vocabulary.count == 64)
        #expect(content.vocabularyBox.current.count == 64)
    }

    // MARK: - Snippets

    @Test("snippet CRUD via the async wrappers, and snippetsBox refreshes after insert")
    func snippetsCRUD() async throws {
        let content = makeContent(dir: TemporaryDirectory())
        let snippet = try await content.snippets.insert(trigger: "/sig", body: "Best, Artem")
        #expect(snippet?.trigger == "/sig")
        #expect(content.snippetsBox.current == [SnippetRule(trigger: "/sig", body: "Best, Artem", onlyInBundleID: nil)])

        let all = await content.snippets.all()
        #expect(all.map(\.trigger) == ["/sig"])

        try await content.snippets.delete(id: try #require(all.first).id)
        #expect(await content.snippets.all().isEmpty)
        #expect(content.snippetsBox.current.isEmpty)
    }

    @Test("snippet onlyIn round-trips into snippetsBox's SnippetRule.onlyInBundleID")
    func snippetOnlyInRoundTrips() async throws {
        let content = makeContent(dir: TemporaryDirectory())
        _ = try await content.snippets.insert(trigger: "/standup", body: "Daily standup notes", onlyIn: (bundleID: "com.apple.mail", appName: "Mail"))
        #expect(content.snippetsBox.current.first?.onlyInBundleID == "com.apple.mail")
    }

    // MARK: - Style overrides

    @Test("style overrides via the async wrappers, and overridesBox refreshes after set/remove")
    func overridesCRUD() async throws {
        let content = makeContent(dir: TemporaryDirectory())
        try await content.overrides.set(bundleID: "com.apple.mail", appName: "Mail", style: .formal)
        #expect(content.overridesBox.current["com.apple.mail"] == .formal)
        #expect(await content.overrides.style(for: "com.apple.mail") == .formal)

        try await content.overrides.remove(bundleID: "com.apple.mail")
        #expect(content.overridesBox.current["com.apple.mail"] == nil)
        #expect(await content.overrides.style(for: "com.apple.mail") == nil)
    }

    // MARK: - noteUses

    @Test("noteUses bumps dictionary and snippet uses, then refreshes the boxes")
    func noteUsesBumpsCounters() async throws {
        let content = makeContent(dir: TemporaryDirectory())
        _ = try await content.dictionary.insert(word: "Kubernetes", soundsLike: nil, type: .term, fixTyping: false)
        _ = try await content.snippets.insert(trigger: "/sig", body: "Best, Artem")

        await content.noteUses(words: ["We", "deployed", "Kubernetes", "today"], snippets: ["/sig"])

        let entry = try #require(await content.dictionary.find(word: "Kubernetes"))
        #expect(entry.uses == 1)
        let snippet = try #require(await content.snippets.find(trigger: "/sig"))
        #expect(snippet.uses == 1)
        // Most-used-first ordering means the bumped snippet still refreshes into the box.
        #expect(content.snippetsBox.current.contains(SnippetRule(trigger: "/sig", body: "Best, Artem", onlyInBundleID: nil)))
    }

    // MARK: - Unavailable database

    @Test("operations are no-ops returning empty results when the database file itself can never open")
    func noOpsWhenDatabaseFileUnopenable() async throws {
        // A path inside a location that doesn't exist and can't be created (a file, not a directory,
        // sits where a parent directory is needed) — `VoxFlowDatabase.init(url:)` itself fails, so
        // `HistoryService.database` never becomes non-nil for `ContentService` to build stores on.
        let dir = TemporaryDirectory()
        let blocker = dir.file("blocker")
        try Data().write(to: blocker)
        let url = blocker.appendingPathComponent("nested").appendingPathComponent("voxflow.sqlite")

        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let history = HistoryService(url: url, settings: settings, keyProvider: { DummyKeyProvider() }, clock: FakeClock())
        let content = ContentService(history: history)

        await content.ready()
        #expect(content.status == .unavailable)
        #expect(await content.dictionary.all().isEmpty)
        #expect(await content.dictionary.vocabulary().isEmpty)
        let inserted = try await content.dictionary.insert(word: "Kubernetes", soundsLike: nil, type: .term, fixTyping: false)
        #expect(inserted == nil)
        #expect(await content.snippets.all().isEmpty)
        #expect(await content.overrides.all().isEmpty)
        await content.noteUses(words: ["hello"], snippets: ["/sig"])   // must not crash or hang
    }

    @Test("content stays available when history alone is disabled (key lost) — dictionary/snippets/styles aren't encrypted")
    func contentWorksWhileHistoryDisabled() async throws {
        let dir = TemporaryDirectory()
        let url = dir.file("voxflow.sqlite")
        // Seed an encrypted row, then point history at a key provider that reports a freshly
        // generated key over that already-encrypted database — `HistoryService` disables itself
        // (`.keyLost`) but its `database` stays open (this task's fix).
        let sharedKey = SymmetricKey(size: .bits256)
        let seedStore = try DictationStore(databaseURL: url, keyProvider: SharedKeyProvider(key: sharedKey, isNew: false))
        try seedStore.insert(DictationDraft(text: "secret", rawText: "secret", appName: nil, style: nil, language: nil, duration: 1, createdAt: Date()))
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let history = HistoryService(url: url, settings: settings,
                                     keyProvider: { SharedKeyProvider(key: SymmetricKey(size: .bits256), isNew: true) }, clock: FakeClock())
        let content = ContentService(history: history)

        await content.ready()
        #expect(history.status == .disabled(reason: "history key lost"))
        #expect(history.store == nil)
        #expect(content.status == .ready)

        let entry = try await content.dictionary.insert(word: "Kubernetes", soundsLike: nil, type: .term, fixTyping: false)
        #expect(entry?.word == "Kubernetes")
        #expect(content.vocabularyBox.current.contains("Kubernetes"))
    }
}

private struct SharedKeyProvider: HistoryKeyProviding {
    let key: SymmetricKey
    var isNew: Bool = false
    func historyKey() throws -> HistoryKey { HistoryKey(key: key, isNewlyCreated: isNew) }
}
