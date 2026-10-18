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

    @Test("update to another row's folded word throws .duplicate with that row's id, not a raw DatabaseError")
    func updateCollidesWithAnotherRow() throws {
        let store = try store()
        let kept = try store.insert(word: "Kubernetes", soundsLike: nil, type: .term, fixTyping: false)
        var toRename = try store.insert(word: "Docker", soundsLike: nil, type: .term, fixTyping: false)
        toRename.word = "kubernetes"
        #expect(throws: StorageError.duplicate(existingID: kept.id)) {
            try store.update(toRename)
        }
        // the write did not go through: the original row is untouched.
        #expect(try store.find(word: "docker")?.word == "Docker")
    }

    @Test("update to a case variant of its own value succeeds")
    func updateToOwnCaseVariantSucceeds() throws {
        let store = try store()
        var entry = try store.insert(word: "term", soundsLike: nil, type: .term, fixTyping: false)
        entry.word = "TERM"
        try store.update(entry)
        #expect(try store.find(word: "term")?.word == "TERM")
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

    @Test("incrementUses(inText:) matches a folded whole word, once per call regardless of how many times it occurs")
    func incrementUsesWholeWord() throws {
        let store = try store()
        _ = try store.insert(word: "Kubernetes", soundsLike: nil, type: .term, fixTyping: false)
        try store.incrementUses(inText: "I love kubernetes so much KUBERNETES")
        #expect(try store.find(word: "kubernetes")?.uses == 1)
    }

    @Test("I3: incrementUses(inText:) matches a multi-word phrase at word boundaries, e.g. a Contacts full name")
    func incrementUsesMultiWordPhrase() throws {
        let store = try store()
        _ = try store.insert(word: "Priya Raghunathan", soundsLike: nil, type: .name, fixTyping: false, source: "contacts")
        try store.incrementUses(inText: "hi priya raghunathan here")
        #expect(try store.find(word: "priya raghunathan")?.uses == 1)
    }

    @Test("I3: incrementUses(inText:) does not match a word as a substring of a longer word")
    func incrementUsesDoesNotMatchSubstring() throws {
        let store = try store()
        _ = try store.insert(word: "Kubernetes", soundsLike: nil, type: .term, fixTyping: false)
        try store.incrementUses(inText: "kubernetesish is not a real word")
        #expect(try store.find(word: "kubernetes")?.uses == 0)
    }

    @Test("symbol entries match standalone without matching inside longer tokens")
    func incrementUsesSymbolEntries() throws {
        let store = try store()
        _ = try store.insert(word: "C++", soundsLike: nil, type: .term, fixTyping: false)
        _ = try store.insert(word: ".NET", soundsLike: nil, type: .term, fixTyping: false)

        try store.incrementUses(inText: "XC++ C++Builder asp.NETwork")
        #expect(try store.find(word: "C++")?.uses == 0)
        #expect(try store.find(word: ".NET")?.uses == 0)

        try store.incrementUses(inText: "Use (C++) and [.NET].")
        #expect(try store.find(word: "C++")?.uses == 1)
        #expect(try store.find(word: ".NET")?.uses == 1)
    }

    @Test("multi-word matching accepts flexible whitespace and keeps diacritic folding")
    func incrementUsesFlexibleWhitespace() throws {
        let store = try store()
        _ = try store.insert(word: "Tāmaki Makaurau", soundsLike: nil, type: .place, fixTyping: false)

        try store.incrementUses(inText: "TAMAKI\t\n  makaURAu is here")

        #expect(try store.find(word: "tamaki makaurau")?.uses == 1)
    }

    @Test("I3: incrementUses(inText:) bumps every matching entry by at most one per call")
    func incrementUsesOncePerEntryPerCall() throws {
        let store = try store()
        _ = try store.insert(word: "Kubernetes", soundsLike: nil, type: .term, fixTyping: false)
        _ = try store.insert(word: "Docker", soundsLike: nil, type: .term, fixTyping: false)
        try store.incrementUses(inText: "we deployed kubernetes and kubernetes and docker today")
        #expect(try store.find(word: "kubernetes")?.uses == 1)
        #expect(try store.find(word: "docker")?.uses == 1)
        try store.incrementUses(inText: "kubernetes again")
        #expect(try store.find(word: "kubernetes")?.uses == 2)
    }

    @Test("vocabulary orders by uses desc then alphabetical, capped at limit")
    func vocabulary() throws {
        let store = try store()
        _ = try store.insert(word: "alpha", soundsLike: nil, type: .term, fixTyping: false)
        _ = try store.insert(word: "beta", soundsLike: nil, type: .term, fixTyping: false)
        _ = try store.insert(word: "gamma", soundsLike: nil, type: .term, fixTyping: false)
        try store.incrementUses(inText: "beta")
        try store.incrementUses(inText: "beta")
        try store.incrementUses(inText: "gamma")
        #expect(try store.vocabulary(limit: 10) == ["beta", "gamma", "alpha"])
        #expect(try store.vocabulary(limit: 2) == ["beta", "gamma"])
    }

    @Test("vocabulary prefers user entries to contacts when usage ties")
    func vocabularyPrefersUserAtEqualUsage() throws {
        let store = try store()
        _ = try store.insert(word: "Alpha", soundsLike: nil, type: .name, fixTyping: false, source: "contacts")
        _ = try store.insert(word: "Zulu", soundsLike: nil, type: .term, fixTyping: false, source: "user")
        _ = try store.insert(word: "Beta", soundsLike: nil, type: .term, fixTyping: false, source: "user")

        #expect(try store.vocabulary(limit: 3) == ["Beta", "Zulu", "Alpha"])
        #expect(try store.vocabulary(limit: 2) == ["Beta", "Zulu"])
    }
}
