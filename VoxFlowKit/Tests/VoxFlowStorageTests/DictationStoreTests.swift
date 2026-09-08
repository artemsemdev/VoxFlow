import CryptoKit
import Foundation
import Testing
@testable import VoxFlowStorage

struct FakeKeyProvider: HistoryKeyProviding {
    let key = SymmetricKey(size: .bits256)
    func historyKey() throws -> SymmetricKey { key }
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
}
