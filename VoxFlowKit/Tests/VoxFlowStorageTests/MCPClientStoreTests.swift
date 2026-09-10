import Foundation
import GRDB
import Testing
@testable import VoxFlowStorage

@Suite("MCPClientStore")
struct MCPClientStoreTests {
    func store() throws -> MCPClientStore { MCPClientStore(database: try VoxFlowDatabase.inMemory()) }

    @Test("recordSighting then all() returns it, unapproved")
    func recordSightingThenAll() throws {
        let store = try store()
        let now = Date(timeIntervalSince1970: 1_000)
        try store.recordSighting(name: "Cursor", path: "/Applications/Cursor.app/Contents/MacOS/Cursor", now: now)
        let all = try store.all()
        #expect(all.count == 1)
        #expect(all.first?.name == "Cursor")
        #expect(all.first?.path == "/Applications/Cursor.app/Contents/MacOS/Cursor")
        #expect(all.first?.approved == false)
        #expect(all.first?.firstSeen == now)
        #expect(all.first?.lastSeen == now)
    }

    @Test("a second recordSighting for the same name+path updates last_seen without a duplicate row, and never touches approved")
    func secondSightingTouchesNotDuplicatesAndPreservesApproval() throws {
        let store = try store()
        let first = Date(timeIntervalSince1970: 1_000)
        let approvedAt = Date(timeIntervalSince1970: 1_500)
        let second = Date(timeIntervalSince1970: 2_000)
        try store.recordSighting(name: "Cursor", path: "/Applications/Cursor.app/Contents/MacOS/Cursor", now: first)
        try store.approve(name: "Cursor", path: "/Applications/Cursor.app/Contents/MacOS/Cursor", now: approvedAt)
        try store.recordSighting(name: "Cursor", path: "/Applications/Cursor.app/Contents/MacOS/Cursor", now: second)

        let all = try store.all()
        #expect(all.count == 1)
        #expect(all.first?.approved == true) // a plain sighting never de-approves.
        #expect(all.first?.firstSeen == first) // first_seen doesn't move on touch
        #expect(all.first?.lastSeen == second)
    }

    @Test("recordSighting returns the record")
    func recordSightingReturnsRecord() throws {
        let store = try store()
        let now = Date(timeIntervalSince1970: 1_000)
        let record = try store.recordSighting(name: "Cursor", path: "/path/Cursor", now: now)
        #expect(record.name == "Cursor")
        #expect(record.approved == false)
    }

    @Test("approve sets approved and also touches last_seen")
    func approveSetsApprovedAndTouches() throws {
        let store = try store()
        let seenAt = Date(timeIntervalSince1970: 1_000)
        let approvedAt = Date(timeIntervalSince1970: 2_000)
        try store.recordSighting(name: "Cursor", path: "/path/Cursor", now: seenAt)
        let record = try store.approve(name: "Cursor", path: "/path/Cursor", now: approvedAt)
        #expect(record.approved == true)
        #expect(record.lastSeen == approvedAt)
        #expect(record.firstSeen == seenAt) // approve doesn't move first_seen either
    }

    @Test("approve on a client never seen before inserts it approved")
    func approveWithoutPriorSighting() throws {
        let store = try store()
        let now = Date(timeIntervalSince1970: 1_000)
        let record = try store.approve(name: "Cursor", path: "/path/Cursor", now: now)
        #expect(record.approved == true)
        #expect(record.firstSeen == now)
    }

    @Test("revoke removes the row")
    func revokeRemoves() throws {
        let store = try store()
        let record = try store.approve(name: "Cursor", path: "/path/Cursor", now: Date())
        try store.revoke(id: record.id)
        #expect(try store.all().isEmpty)
    }

    @Test("a sighting after a revoke leaves the client revoked, not silently re-approved")
    func sightingAfterRevokeStaysRevoked() throws {
        let store = try store()
        let record = try store.approve(name: "Cursor", path: "/path/Cursor", now: Date(timeIntervalSince1970: 1_000))
        try store.revoke(id: record.id)

        try store.recordSighting(name: "Cursor", path: "/path/Cursor", now: Date(timeIntervalSince1970: 2_000))

        let all = try store.all()
        #expect(all.count == 1)
        #expect(all.first?.approved == false)
    }

    @Test("revokeAll removes every row")
    func revokeAllRemoves() throws {
        let store = try store()
        try store.approve(name: "Cursor", path: "/path/Cursor", now: Date())
        try store.approve(name: "Claude Desktop", path: "/path/Claude", now: Date())
        try store.revokeAll()
        #expect(try store.all().isEmpty)
    }

    @Test("distinct name+path pairs stay distinct rows")
    func distinctClientsStayDistinct() throws {
        let store = try store()
        try store.recordSighting(name: "Cursor", path: "/path/Cursor", now: Date())
        try store.recordSighting(name: "Cursor", path: "/other/path/Cursor", now: Date())
        #expect(try store.all().count == 2)
    }

    @Test("the v3 migration runs on a database created at v2")
    func migratesFromV2() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voxflow.sqlite")

        // A pre-phase-6 database: only v1/v2 have ever run, recorded in GRDB's migrations table
        // exactly as a real installed app would leave it.
        let rawQueue = try DatabaseQueue(path: url.path)
        var v2Only = DatabaseMigrator()
        v2Only.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE dictations (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, created_at DOUBLE NOT NULL, app_name TEXT, style TEXT, language TEXT,
                  duration DOUBLE NOT NULL, words INTEGER NOT NULL, encrypted BOOLEAN NOT NULL, text BLOB NOT NULL, raw_text BLOB NOT NULL);
                CREATE INDEX dictations_created_at ON dictations(created_at);
                """)
        }
        v2Only.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE TABLE dictionary (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  word TEXT NOT NULL, word_folded TEXT NOT NULL UNIQUE,
                  sounds_like TEXT, type TEXT NOT NULL,
                  fix_typing BOOLEAN NOT NULL DEFAULT 0,
                  source TEXT NOT NULL DEFAULT 'user',
                  uses INTEGER NOT NULL DEFAULT 0, created_at DOUBLE NOT NULL);
                CREATE TABLE snippets (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  trigger TEXT NOT NULL, trigger_folded TEXT NOT NULL UNIQUE,
                  body TEXT NOT NULL, only_in_bundle_id TEXT, only_in_app_name TEXT,
                  uses INTEGER NOT NULL DEFAULT 0, created_at DOUBLE NOT NULL);
                CREATE TABLE app_style_overrides (
                  bundle_id TEXT PRIMARY KEY, app_name TEXT NOT NULL, style TEXT NOT NULL);
                """)
        }
        try v2Only.migrate(rawQueue)

        let database = try VoxFlowDatabase(url: url)
        let tableNames: [String] = try database.queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tableNames.contains("mcp_clients"))

        // And the store actually works against the migrated table.
        let store = MCPClientStore(database: database)
        try store.recordSighting(name: "Cursor", path: "/path/Cursor", now: Date())
        #expect(try store.all().count == 1)
    }
}
