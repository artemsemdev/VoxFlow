import Foundation
import GRDB
import Testing
@testable import VoxFlowStorage

@Suite("VoxFlowDatabase")
struct VoxFlowDatabaseTests {
    @Test("opening a v1-only database file adds the v2 tables")
    func migratesFromV1() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voxflow.sqlite")

        // A pre-phase-4a database: only the v1 (dictations) migration has ever run, recorded in
        // GRDB's own migrations table exactly as a real installed app would leave it.
        let rawQueue = try DatabaseQueue(path: url.path)
        defer {
            do { try rawQueue.close() } catch { Issue.record("raw migration queue close failed: \(error)") }
        }
        var v1Only = DatabaseMigrator()
        v1Only.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE dictations (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, created_at DOUBLE NOT NULL, app_name TEXT, style TEXT, language TEXT,
                  duration DOUBLE NOT NULL, words INTEGER NOT NULL, encrypted BOOLEAN NOT NULL, text BLOB NOT NULL, raw_text BLOB NOT NULL);
                CREATE INDEX dictations_created_at ON dictations(created_at);
                """)
        }
        try v1Only.migrate(rawQueue)

        let database = try VoxFlowDatabase(url: url)
        defer {
            do { try database.queue.close() } catch { Issue.record("database queue close failed: \(error)") }
        }
        let tableNames: [String] = try database.queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tableNames.contains("dictations"))
        #expect(tableNames.contains("dictionary"))
        #expect(tableNames.contains("snippets"))
        #expect(tableNames.contains("app_style_overrides"))
        let annotationColumn: Int = try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_table_info('dictations') WHERE name = 'annotations'") ?? 0
        }
        #expect(annotationColumn == 1)
    }

    @Test("inMemory creates a fresh database with all tables")
    func inMemoryCreatesTables() throws {
        let database = try VoxFlowDatabase.inMemory()
        let tableNames: [String] = try database.queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tableNames.contains("dictations"))
        #expect(tableNames.contains("dictionary"))
        #expect(tableNames.contains("snippets"))
        #expect(tableNames.contains("app_style_overrides"))
    }
}
