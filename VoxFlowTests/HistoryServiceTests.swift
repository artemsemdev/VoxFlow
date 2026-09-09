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
        HistoryService(url: dir.file("voxflow.sqlite"), settings: settings,
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
        let original = try #require(service.store).insert(draft("undo me", at: Date(timeIntervalSince1970: 500)))

        await service.delete(id: original.id)
        #expect(await service.count() == 0)

        let restored = await service.reinsert(original)
        #expect(restored?.text == "undo me")
        #expect(restored?.createdAt == original.createdAt)
        #expect(await service.count() == 1)
    }

    @Test("a key provider reporting a freshly-created key over an already-encrypted database disables history")
    func keyLostDisablesHistory() async throws {
        let dir = TemporaryDirectory()
        let url = dir.file("voxflow.sqlite")
        let sharedKey = SymmetricKey(size: .bits256)
        _ = try DictationStore(databaseURL: url, keyProvider: FakeHistoryKeyProvider(key: sharedKey)).insert(draft("secret", at: Date()))

        let settings = DictationSettings(store: InMemoryKeyValueStore())
        let service = HistoryService(url: url, settings: settings,
                                     keyProvider: { FakeHistoryKeyProvider(key: SymmetricKey(size: .bits256), isNew: true) }, clock: FakeClock())
        _ = await service.count()                                     // force the open to finish

        #expect(service.status == .disabled(reason: "history key lost"))
        #expect(service.store == nil)
    }
}
