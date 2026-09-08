import CryptoKit
import Foundation
import Testing
@testable import VoxFlowStorage

struct FakeKeyProvider: HistoryKeyProviding {
    let key: SymmetricKey
    var isNew: Bool
    init(key: SymmetricKey = SymmetricKey(size: .bits256), isNew: Bool = false) {
        self.key = key
        self.isNew = isNew
    }
    func historyKey() throws -> HistoryKey { HistoryKey(key: key, isNewlyCreated: isNew) }
}

@Suite("DictationStore")
struct DictationStoreTests {
    func draft(_ text: String, at date: Date, app: String? = "Mail") -> DictationDraft {
        DictationDraft(text: text, rawText: text + " raw", appName: app, style: nil, language: "en", duration: 2.5, createdAt: date)
    }

    @Test("insert then fetch newest first; word count derived from text")
    func insertFetch() throws {
        let store = try DictationStore(inMemoryWith: nil)
        let older = try store.insert(draft("first one", at: Date(timeIntervalSince1970: 100)))
        let newer = try store.insert(draft("second one here", at: Date(timeIntervalSince1970: 200)))
        let all = try store.fetch(limit: 10)
        #expect(all.map(\.id) == [newer.id, older.id])
        #expect(all.first?.words == 3)
        #expect(all.first?.rawText == "second one here raw")
        #expect(try store.count() == 2)
    }

    @Test("encrypted rows are unreadable in SQL and transparent through the store")
    func encryption() throws {
        let store = try DictationStore(inMemoryWith: FakeKeyProvider())
        _ = try store.insert(draft("secret words", at: Date()))
        let raw = try store.textColumnForTesting(id: 1)
        #expect(raw != Data("secret words".utf8))
        #expect(try store.fetch(limit: 1).first?.text == "secret words")
    }

    @Test("search matches text or raw transcript, case-insensitive, after decryption")
    func search() throws {
        let store = try DictationStore(inMemoryWith: FakeKeyProvider())
        _ = try store.insert(draft("Quarterly numbers look fine", at: Date(timeIntervalSince1970: 1)))
        _ = try store.insert(DictationDraft(text: "clean", rawText: "um clean NUMBERS", appName: nil, style: nil, language: nil, duration: 1, createdAt: Date(timeIntervalSince1970: 2)))
        _ = try store.insert(draft("unrelated", at: Date(timeIntervalSince1970: 3)))
        #expect(try store.search("numbers").map(\.text) == ["clean", "Quarterly numbers look fine"])
        #expect(try store.search("  ").count == 3)
    }

    @Test("delete one, delete all, delete older than a cutoff")
    func deletes() throws {
        let store = try DictationStore(inMemoryWith: nil)
        let a = try store.insert(draft("a", at: Date(timeIntervalSince1970: 10)))
        _ = try store.insert(draft("b", at: Date(timeIntervalSince1970: 20)))
        _ = try store.insert(draft("c", at: Date(timeIntervalSince1970: 30)))
        try store.delete(id: a.id)
        #expect(try store.count() == 2)
        #expect(try store.deleteOlderThan(Date(timeIntervalSince1970: 25)) == 1)
        #expect(try store.fetch(limit: 10).map(\.text) == ["c"])
        try store.deleteAll()
        #expect(try store.count() == 0)
    }

    @Test("a file-backed store persists across instances")
    func persistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voxflow.sqlite")
        _ = try DictationStore(databaseURL: url, keyProvider: nil).insert(draft("kept", at: Date()))
        #expect(try DictationStore(databaseURL: url, keyProvider: nil).fetch(limit: 1).first?.text == "kept")
    }

    @Test("fetch never fails on an unreadable row: reopening without the key flags encrypted rows, plaintext still reads")
    func unreadableRowsDoNotBreakFetch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voxflow.sqlite")

        let keyed = try DictationStore(databaseURL: url, keyProvider: FakeKeyProvider())
        _ = try keyed.insert(draft("first secret", at: Date(timeIntervalSince1970: 1)))
        _ = try keyed.insert(draft("second secret", at: Date(timeIntervalSince1970: 2)))

        let reopened = try DictationStore(databaseURL: url, keyProvider: nil)
        let all = try reopened.fetch(limit: 10)
        #expect(all.count == 2)
        #expect(all.allSatisfy { $0.isUnreadable })
        #expect(all.allSatisfy { $0.text.isEmpty && $0.rawText.isEmpty })
        #expect(try reopened.search("secret").isEmpty)   // unreadable rows never surface in search

        _ = try reopened.insert(draft("plain text after", at: Date(timeIntervalSince1970: 3)))
        let afterInsert = try reopened.fetch(limit: 10)
        #expect(afterInsert.count == 3)
        #expect(afterInsert.filter(\.isUnreadable).count == 2)
        let readable = afterInsert.first { !$0.isUnreadable }
        #expect(readable?.text == "plain text after")
        #expect(try reopened.search("plain").map(\.text) == ["plain text after"])
    }

    @Test("a key provider reporting a freshly-created key over an already-encrypted database throws keyLost; the existing key still works")
    func lostKeyIsDetected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voxflow.sqlite")
        let sharedKey = SymmetricKey(size: .bits256)

        _ = try DictationStore(databaseURL: url, keyProvider: FakeKeyProvider(key: sharedKey)).insert(draft("secret", at: Date()))

        #expect(throws: StorageError.keyLost) {
            _ = try DictationStore(databaseURL: url, keyProvider: FakeKeyProvider(key: SymmetricKey(size: .bits256), isNew: true))
        }

        let reopened = try DictationStore(databaseURL: url, keyProvider: FakeKeyProvider(key: sharedKey, isNew: false))
        #expect(try reopened.count() == 1)
        #expect(try reopened.fetch(limit: 1).first?.text == "secret")
    }
}
