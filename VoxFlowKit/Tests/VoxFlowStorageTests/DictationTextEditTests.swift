import Foundation
import GRDB
import Testing
@testable import VoxFlowStorage

@Suite("Dictation text editing")
struct DictationTextEditTests {
    private var draft: DictationDraft {
        DictationDraft(text: "old text", rawText: "um original words", appName: "Mail", style: "formal",
                       language: "en", duration: 2.5, createdAt: Date(timeIntervalSince1970: 10))
    }

    @Test("editing persists only text and word count, preserving transcript and metadata", arguments: [false, true])
    func roundTrip(encrypted: Bool) throws {
        let store = try DictationStore(inMemoryWith: encrypted ? FakeKeyProvider() : nil)
        let original = try store.insert(draft)
        let updated = try #require(try store.updateText(id: original.id, text: "Corrected\nthree words"))
        #expect(updated.text == "Corrected\nthree words")
        #expect(updated.words == 3)
        #expect(updated.rawText == original.rawText)
        #expect(updated.style == original.style)
        #expect(updated.id == original.id)
        #expect(updated.appName == original.appName)
        #expect(updated.language == original.language)
        #expect(updated.duration == original.duration)
        #expect(updated.createdAt == original.createdAt)
        #expect(try store.fetch(limit: 1).first == updated)
        #expect(try store.search("corrected").count == 1)
        #expect(try store.search("original").count == 1)
    }

    @Test("editing after enabling encryption seals both columns and preserves a nil style")
    func enablingEncryption() throws {
        let database = try VoxFlowDatabase.inMemory()
        let plain = try DictationStore(database: database, keyProvider: nil)
        var value = draft
        value.style = nil
        let original = try plain.insert(value)
        let encrypted = try DictationStore(database: database, keyProvider: FakeKeyProvider())
        let updated = try #require(try encrypted.updateText(id: original.id, text: "Corrected"))
        #expect(updated.rawText == original.rawText)
        #expect(updated.style == nil)
        let row = try #require(database.queue.read { try Row.fetchOne($0, sql: "SELECT * FROM dictations") })
        #expect((row["encrypted"] as Bool) == true)
        #expect((row["text"] as Data) != Data("Corrected".utf8))
        #expect((row["raw_text"] as Data) != Data(original.rawText.utf8))
        #expect(try encrypted.fetch(limit: 1).first == updated)
    }

    @Test("a missing or wrong key leaves every column byte-for-byte untouched", arguments: [false, true])
    func unreadable(wrongKey: Bool) throws {
        let database = try VoxFlowDatabase.inMemory()
        let keyed = try DictationStore(database: database, keyProvider: FakeKeyProvider())
        let original = try keyed.insert(draft)
        let before = try database.queue.read { try Row.fetchOne($0, sql: "SELECT * FROM dictations") }
        let unreadable = try DictationStore(database: database, keyProvider: wrongKey ? FakeKeyProvider() : nil)
        #expect(try unreadable.updateText(id: original.id, text: "Attempted overwrite") == nil)
        let after = try database.queue.read { try Row.fetchOne($0, sql: "SELECT * FROM dictations") }
        #expect(after == before)
        #expect(try keyed.fetch(limit: 1).first == original)
    }

    @Test("editing a missing id does not create a row")
    func missing() throws {
        let store = try DictationStore(inMemoryWith: nil)
        #expect(try store.updateText(id: 42, text: "Correction") == nil)
        #expect(try store.count() == 0)
    }
}
