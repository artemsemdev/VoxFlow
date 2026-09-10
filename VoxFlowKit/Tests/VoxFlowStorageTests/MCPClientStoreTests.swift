import Foundation
import GRDB
import Testing
@testable import VoxFlowStorage

@Suite("MCPClientStore")
struct MCPClientStoreTests {
    func store() throws -> MCPClientStore { MCPClientStore(database: try VoxFlowDatabase.inMemory()) }

    @Test("insertOrTouch then all() returns it")
    func insertThenAll() throws {
        let store = try store()
        let now = Date(timeIntervalSince1970: 1_000)
        try store.insertOrTouch(name: "Cursor", path: "/Applications/Cursor.app/Contents/MacOS/Cursor", approved: false, now: now)
        let all = try store.all()
        #expect(all.count == 1)
        #expect(all.first?.name == "Cursor")
        #expect(all.first?.path == "/Applications/Cursor.app/Contents/MacOS/Cursor")
        #expect(all.first?.approved == false)
        #expect(all.first?.firstSeen == now)
        #expect(all.first?.lastSeen == now)
    }

    @Test("a second insertOrTouch for the same name+path updates last_seen and approved without a duplicate row")
    func secondCallTouchesNotDuplicates() throws {
        let store = try store()
        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 2_000)
        try store.insertOrTouch(name: "Cursor", path: "/Applications/Cursor.app/Contents/MacOS/Cursor", approved: false, now: first)
        try store.insertOrTouch(name: "Cursor", path: "/Applications/Cursor.app/Contents/MacOS/Cursor", approved: true, now: second)

        let all = try store.all()
        #expect(all.count == 1)
        #expect(all.first?.approved == true)
        #expect(all.first?.firstSeen == first) // first_seen doesn't move on touch
        #expect(all.first?.lastSeen == second)
    }

    @Test("insertOrTouch returns the record")
    func returnsRecord() throws {
        let store = try store()
        let now = Date(timeIntervalSince1970: 1_000)
        let record = try store.insertOrTouch(name: "Cursor", path: "/path/Cursor", approved: true, now: now)
        #expect(record.name == "Cursor")
        #expect(record.approved == true)
    }

    @Test("revoke removes the row")
    func revokeRemoves() throws {
        let store = try store()
        let record = try store.insertOrTouch(name: "Cursor", path: "/path/Cursor", approved: true, now: Date())
        try store.revoke(id: record.id)
        #expect(try store.all().isEmpty)
    }

    @Test("revokeAll removes every row")
    func revokeAllRemoves() throws {
        let store = try store()
        try store.insertOrTouch(name: "Cursor", path: "/path/Cursor", approved: true, now: Date())
        try store.insertOrTouch(name: "Claude Desktop", path: "/path/Claude", approved: true, now: Date())
        try store.revokeAll()
        #expect(try store.all().isEmpty)
    }

    @Test("distinct name+path pairs stay distinct rows")
    func distinctClientsStayDistinct() throws {
        let store = try store()
        try store.insertOrTouch(name: "Cursor", path: "/path/Cursor", approved: false, now: Date())
        try store.insertOrTouch(name: "Cursor", path: "/other/path/Cursor", approved: false, now: Date())
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
        try store.insertOrTouch(name: "Cursor", path: "/path/Cursor", approved: true, now: Date())
        #expect(try store.all().count == 1)
    }
}
