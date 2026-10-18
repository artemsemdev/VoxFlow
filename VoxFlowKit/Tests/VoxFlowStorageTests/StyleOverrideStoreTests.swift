import Foundation
import Testing
import VoxFlowCore
@testable import VoxFlowStorage

@Suite("StyleOverrideStore")
struct StyleOverrideStoreTests {
    func store() throws -> StyleOverrideStore { StyleOverrideStore(database: try VoxFlowDatabase.inMemory()) }

    @Test("set then style(for:) round-trips")
    func setAndLookup() throws {
        let store = try store()
        try store.set(bundleID: "com.apple.mail", appName: "Mail", style: .formal)
        #expect(try store.style(for: "com.apple.mail") == .formal)
        #expect(try store.style(for: "com.missing") == nil)
    }

    @Test("set upserts: a second call for the same bundle id replaces the style")
    func upsert() throws {
        let store = try store()
        try store.set(bundleID: "com.apple.mail", appName: "Mail", style: .formal)
        try store.set(bundleID: "com.apple.mail", appName: "Mail", style: .verbatim)
        #expect(try store.style(for: "com.apple.mail") == .verbatim)
        #expect(try store.all().count == 1)
    }

    @Test("remove deletes the override")
    func remove() throws {
        let store = try store()
        try store.set(bundleID: "com.apple.mail", appName: "Mail", style: .casual)
        try store.remove(bundleID: "com.apple.mail")
        #expect(try store.style(for: "com.apple.mail") == nil)
    }

    @Test("all orders by app name")
    func allOrdering() throws {
        let store = try store()
        try store.set(bundleID: "com.b", appName: "Beta", style: .casual)
        try store.set(bundleID: "com.a", appName: "Alpha", style: .formal)
        #expect(try store.all().map(\.appName) == ["Alpha", "Beta"])
    }
}
