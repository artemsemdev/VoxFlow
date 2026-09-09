import Foundation
import Testing
import VoxFlowCore
@testable import VoxFlowStorage

@Suite("DictionaryStore")
struct DictionaryStoreTests {
    func store() throws -> DictionaryStore { DictionaryStore(database: try VoxFlowDatabase.inMemory()) }

    @Test("insert then all: alphabetical by folded word")
    func insertAndAll() throws {
        let store = try store()
        _ = try store.insert(word: "Zebra", soundsLike: nil, type: .term, fixTyping: false)
        _ = try store.insert(word: "apple", soundsLike: nil, type: .term, fixTyping: false)
        _ = try store.insert(word: "Mango", soundsLike: nil, type: .term, fixTyping: false)
        #expect(try store.all().map(\.word) == ["apple", "Mango", "Zebra"])
    }

    @Test("duplicate detection is case- and diacritic-insensitive")
    func duplicateDetection() throws {
        let store = try store()
        let first = try store.insert(word: "Kubernetes", soundsLike: nil, type: .term, fixTyping: false)
        #expect(throws: StorageError.duplicate(existingID: first.id)) {
            _ = try store.insert(word: "kubernetes", soundsLike: nil, type: .term, fixTyping: false)
        }
        let tamaki = try store.insert(word: "Tāmaki", soundsLike: nil, type: .place, fixTyping: false)
        #expect(throws: StorageError.duplicate(existingID: tamaki.id)) {
            _ = try store.insert(word: "Tamaki", soundsLike: nil, type: .place, fixTyping: false)
        }
    }

    @Test("update changes fields")
    func update() throws {
        let store = try store()
        var entry = try store.insert(word: "term", soundsLike: nil, type: .term, fixTyping: false)
        entry.word = "Term"
        entry.fixTyping = true
        try store.update(entry)
        #expect(try store.find(word: "term")?.fixTyping == true)
        #expect(try store.find(word: "term")?.word == "Term")
    }

    @Test("delete removes the row")
    func delete() throws {
        let store = try store()
        let entry = try store.insert(word: "gone", soundsLike: nil, type: .term, fixTyping: false)
        try store.delete(id: entry.id)
        #expect(try store.all().isEmpty)
    }

    @Test("find matches folded word")
    func find() throws {
        let store = try store()
        _ = try store.insert(word: "Café", soundsLike: nil, type: .place, fixTyping: false)
        #expect(try store.find(word: "cafe")?.word == "Café")
        #expect(try store.find(word: "missing") == nil)
    }

    @Test("removeAll(source:) removes only that source, keeping others")
    func removeAllBySource() throws {
        let store = try store()
        _ = try store.insert(word: "keep", soundsLike: nil, type: .name, fixTyping: false, source: "user")
        _ = try store.insert(word: "drop", soundsLike: nil, type: .name, fixTyping: false, source: "contacts")
        try store.removeAll(source: "contacts")
        #expect(try store.all().map(\.word) == ["keep"])
    }

    @Test("incrementUses matches folded whole words, counting occurrences")
    func incrementUses() throws {
        let store = try store()
        _ = try store.insert(word: "Kubernetes", soundsLike: nil, type: .term, fixTyping: false)
        try store.incrementUses(words: ["I", "love", "kubernetes", "so", "much", "KUBERNETES"])
        #expect(try store.find(word: "kubernetes")?.uses == 2)
    }

    @Test("vocabulary orders by uses desc then alphabetical, capped at limit")
    func vocabulary() throws {
        let store = try store()
        _ = try store.insert(word: "alpha", soundsLike: nil, type: .term, fixTyping: false)
        _ = try store.insert(word: "beta", soundsLike: nil, type: .term, fixTyping: false)
        _ = try store.insert(word: "gamma", soundsLike: nil, type: .term, fixTyping: false)
        try store.incrementUses(words: ["beta", "beta", "gamma"])
        #expect(try store.vocabulary(limit: 10) == ["beta", "gamma", "alpha"])
        #expect(try store.vocabulary(limit: 2) == ["beta", "gamma"])
    }
}
