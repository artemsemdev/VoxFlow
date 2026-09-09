import Foundation
import Testing
@testable import VoxFlowStorage

@Suite("SnippetStore")
struct SnippetStoreTests {
    func store() throws -> SnippetStore { SnippetStore(database: try VoxFlowDatabase.inMemory()) }

    @Test("insert then all: by uses desc then trigger")
    func insertAndAll() throws {
        let store = try store()
        _ = try store.insert(trigger: "sig", body: "Best, A")
        let addr = try store.insert(trigger: "addr", body: "123 Main St")
        try store.incrementUses(id: addr.id)
        #expect(try store.all().map(\.trigger) == ["addr", "sig"])
    }

    @Test("duplicate trigger is case- and diacritic-insensitive")
    func duplicateDetection() throws {
        let store = try store()
        let first = try store.insert(trigger: "Adiós", body: "bye")
        #expect(throws: StorageError.duplicate(existingID: first.id)) {
            _ = try store.insert(trigger: "adios", body: "bye again")
        }
    }

    @Test("update changes body")
    func update() throws {
        let store = try store()
        var snippet = try store.insert(trigger: "sig", body: "old")
        snippet.body = "new"
        try store.update(snippet)
        #expect(try store.find(trigger: "sig")?.body == "new")
    }

    @Test("delete removes the row")
    func delete() throws {
        let store = try store()
        let s = try store.insert(trigger: "gone", body: "x")
        try store.delete(id: s.id)
        #expect(try store.all().isEmpty)
    }

    @Test("find matches folded trigger")
    func find() throws {
        let store = try store()
        _ = try store.insert(trigger: "Café", body: "coffee")
        #expect(try store.find(trigger: "cafe")?.body == "coffee")
        #expect(try store.find(trigger: "missing") == nil)
    }

    @Test("onlyIn round-trips bundle id and app name")
    func onlyInRoundTrip() throws {
        let store = try store()
        _ = try store.insert(trigger: "addr", body: "123 Main St", onlyIn: (bundleID: "com.apple.mail", appName: "Mail"))
        let found = try store.find(trigger: "addr")
        #expect(found?.onlyInBundleID == "com.apple.mail")
        #expect(found?.onlyInAppName == "Mail")
    }

    @Test("incrementUses bumps the count")
    func incrementUses() throws {
        let store = try store()
        let s = try store.insert(trigger: "sig", body: "x")
        try store.incrementUses(id: s.id)
        try store.incrementUses(id: s.id)
        #expect(try store.find(trigger: "sig")?.uses == 2)
    }
}
