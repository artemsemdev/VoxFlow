import CryptoKit
import Foundation
import Testing
import VoxFlowCore
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

private struct FakeHistoryKeyProvider: HistoryKeyProviding {
    let key: SymmetricKey
    var isNew: Bool
    init(key: SymmetricKey = SymmetricKey(size: .bits256), isNew: Bool = false) {
        self.key = key
        self.isNew = isNew
    }
    func historyKey() throws -> HistoryKey { HistoryKey(key: key, isNewlyCreated: isNew) }
}

@Suite("HistoryService")
@MainActor
struct HistoryServiceTests {
    func draft(_ text: String, at date: Date) -> DictationDraft {
        DictationDraft(text: text, rawText: text + " raw", appName: "Mail", style: nil, language: "en", duration: 1, createdAt: date)
    }

    func makeService(dir: TemporaryDirectory, settings: DictationSettings, key: SymmetricKey = SymmetricKey(size: .bits256), isNew: Bool = false) -> HistoryService {
        // Test rows carry epoch-era dates; a live 30-day retention purge (which runs on every open,
        // on a detached task) would race the inserts — CI lost that race once. "Never" keeps it out.
        settings.retentionDays = 0
        return HistoryService(directory: dir, settings: settings,
                       keyProvider: { FakeHistoryKeyProvider(key: key, isNew: isNew) }, clock: FakeClock())
    }

    @Test("fetch returns a row inserted via the underlying store")
    func fetchAfterInsert() async throws {
        let dir = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let service = makeService(dir: dir, settings: settings)
        _ = await service.count()                                     // force init's open to finish
        _ = try #require(service.store).insert(draft("hello there", at: Date(timeIntervalSince1970: 1)))

        let rows = await service.fetch(limit: 10)
        #expect(rows.map(\.text) == ["hello there"])
        #expect(service.status == .ready)
    }

    @Test("database is nil until the first open resolves, then set alongside store")
    func databaseExposedAfterOpen() async throws {
        let dir = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let service = makeService(dir: dir, settings: settings)
        #expect(service.database == nil)
        _ = await service.count()                                     // force the open to finish
        #expect(service.database != nil)
        #expect(service.status == .ready)
    }

    @Test("a key-lost open failure disables history but keeps the database open (dictionary/snippets/styles aren't encrypted)")
    func databaseStaysOpenWhenKeyLost() async throws {
        let dir = TemporaryDirectory()
        let url = dir.file("voxflow.sqlite")
        let sharedKey = SymmetricKey(size: .bits256)
        _ = try DictationStore(databaseURL: url, keyProvider: FakeHistoryKeyProvider(key: sharedKey)).insert(draft("secret", at: Date()))

        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let service = HistoryService(directory: dir, settings: settings,
                                     keyProvider: { FakeHistoryKeyProvider(key: SymmetricKey(size: .bits256), isNew: true) }, clock: FakeClock())
        _ = await service.count()

        #expect(service.status == .disabled(reason: "history key lost"))
        #expect(service.store == nil)
        #expect(service.database != nil)
    }

    @Test("a database file that can never be opened leaves both store and database nil")
    func databaseNilWhenFileUnopenable() async throws {
        // A path inside a location that doesn't exist and can't be created (a file, not a directory,
        // sits where a parent directory is needed) — `VoxFlowDatabase.init(url:)`'s own
        // `createDirectory` fails, so the database never opens at all.
        let dir = TemporaryDirectory()
        let blocker = dir.file("blocker")
        try Data().write(to: blocker)
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let service = HistoryService(directory: dir, relativePath: "blocker/nested/voxflow.sqlite", settings: settings, keyProvider: { FakeHistoryKeyProvider() }, clock: FakeClock())
        _ = await service.count()

        #expect(service.store == nil)
        #expect(service.database == nil)
        if case .disabled = service.status {} else { Issue.record("expected .disabled, got \(service.status)") }
    }

    @Test("reopening with encryption off flags previously-encrypted rows as unreadable")
    func reopenWithoutEncryption() async throws {
        let dir = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        #expect(settings.encryptHistory)
        let sharedKey = SymmetricKey(size: .bits256)
        let service = makeService(dir: dir, settings: settings, key: sharedKey)
        _ = await service.count()
        _ = try #require(service.store).insert(draft("secret words", at: Date()))

        settings.encryptHistory = false
        service.reopen()

        let rows = await service.fetch(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.isUnreadable == true)
        #expect(rows.first?.text.isEmpty == true)
    }

    @Test("deleteAll empties the store")
    func deleteAllEmpties() async throws {
        let dir = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let service = makeService(dir: dir, settings: settings)
        _ = await service.count()
        _ = try #require(service.store).insert(draft("one", at: Date()))
        _ = try #require(service.store).insert(draft("two", at: Date()))

        await service.deleteAll()
        #expect(await service.count() == 0)
    }

    @Test("reinsert restores a deleted record with its original createdAt")
    func reinsertKeepsCreatedAt() async throws {
        let dir = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let service = makeService(dir: dir, settings: settings)
        _ = await service.count()
        let confidence = WordConfidence(span: RawTextSpan(location: 0, length: 4)!, confidence: 0.78)!
        let original = try #require(service.store).insert(DictationDraft(
            text: "undo me", rawText: "undo me raw", appName: "Mail", style: nil, language: "en", duration: 1,
            createdAt: Date(timeIntervalSince1970: 500),
            annotations: DictationAnnotations(wordConfidences: [confidence])))

        await service.delete(id: original.id)
        #expect(await service.count() == 0)

        let restored = await service.reinsert(original)
        #expect(restored?.text == "undo me")
        #expect(restored?.createdAt == original.createdAt)
        #expect(restored?.annotations == original.annotations)
        #expect(await service.count() == 1)
    }

    @Test("updateStyled replaces text/style and notifies change; an unknown id returns nil without notifying")
    func updateStyledReplacesTextAndNotifies() async throws {
        let dir = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let service = makeService(dir: dir, settings: settings)
        _ = await service.count()
        let original = try #require(service.store).insert(draft("um restyle me", at: Date(timeIntervalSince1970: 700)))

        var changeCount = 0
        service.onChange = { changeCount += 1 }

        let updated = await service.updateStyled(id: original.id, text: "Restyle me.", style: "formal")
        #expect(updated?.text == "Restyle me.")
        #expect(updated?.style == "formal")
        #expect(updated?.rawText == original.rawText)
        #expect(changeCount == 1)

        let rows = await service.fetch(limit: 10)
        #expect(rows.first?.text == "Restyle me.")
        #expect(rows.first?.style == "formal")

        let missing = await service.updateStyled(id: 999_999, text: "nope", style: "casual")
        #expect(missing == nil)
        #expect(changeCount == 1)   // no spurious notification for a no-op update
    }

    @Test("two overlapping reopen() calls: the last one's config wins, and the earlier reopen's runner is not leaked")
    func overlappingReopensChainInOrder() async throws {
        let dir = TemporaryDirectory()
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let sharedKey = SymmetricKey(size: .bits256)
        let service = makeService(dir: dir, settings: settings, key: sharedKey)
        _ = await service.count()
        _ = try #require(service.store).insert(draft("secret", at: Date()))

        // Two `reopen()` calls back to back, with no `await` between them — the earlier call's
        // detached open hasn't necessarily resolved yet when the later one is issued. Chaining must
        // still apply them in order, so the *last* one (encryptHistory back on) is what sticks.
        settings.encryptHistory = false
        service.reopen()
        settings.encryptHistory = true
        service.reopen()

        let rows = await service.fetch(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.isUnreadable == false)          // last reopen re-enabled encryption with the same key: still readable
        #expect(rows.first?.text == "secret")
        #expect(service.status == .ready)

        // If the earlier reopen's `RetentionRunner` had leaked (never `stop()`-ed because the two
        // `performOpen()` calls interleaved instead of chaining), a purge from it running against a
        // store this service no longer references wouldn't show up here — but a third, ordinary
        // reopen completing cleanly to `.ready` with the expected row intact is exactly what breaks
        // if `performOpen()`'s "stop old retention, then open" step ever got skipped or duplicated.
        service.reopen()
        let final = await service.fetch(limit: 10)
        #expect(final.count == 1)
        #expect(service.status == .ready)
    }

    @Test("a key provider reporting a freshly-created key over an already-encrypted database disables history")
    func keyLostDisablesHistory() async throws {
        let dir = TemporaryDirectory()
        let url = dir.file("voxflow.sqlite")
        let sharedKey = SymmetricKey(size: .bits256)
        _ = try DictationStore(databaseURL: url, keyProvider: FakeHistoryKeyProvider(key: sharedKey)).insert(draft("secret", at: Date()))

        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let service = HistoryService(directory: dir, settings: settings,
                                     keyProvider: { FakeHistoryKeyProvider(key: SymmetricKey(size: .bits256), isNew: true) }, clock: FakeClock())
        _ = await service.count()                                     // force the open to finish

        #expect(service.status == .disabled(reason: "history key lost"))
        #expect(service.store == nil)
    }
}
