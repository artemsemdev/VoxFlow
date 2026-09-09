import Foundation
import GRDB

/// Owns the shared SQLite connection and every schema migration (design §5). One database file
/// backs dictation history plus the dictionary, snippets, and per-app style override tables.
public final class VoxFlowDatabase: Sendable {
    public let queue: DatabaseQueue

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoxFlow/voxflow.sqlite")
    }

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        queue = try DatabaseQueue(path: url.path)
        try Self.migrator.migrate(queue)
    }

    public static func inMemory() throws -> VoxFlowDatabase {
        try VoxFlowDatabase(queue: DatabaseQueue())
    }

    private init(queue: DatabaseQueue) throws {
        self.queue = queue
        try Self.migrator.migrate(queue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE dictations (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, created_at DOUBLE NOT NULL, app_name TEXT, style TEXT, language TEXT,
                  duration DOUBLE NOT NULL, words INTEGER NOT NULL, encrypted BOOLEAN NOT NULL, text BLOB NOT NULL, raw_text BLOB NOT NULL);
                CREATE INDEX dictations_created_at ON dictations(created_at);
                """)
        }
        migrator.registerMigration("v2") { db in
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
        return migrator
    }
}

/// Folded matching key shared by `dictionary.word_folded` and `snippets.trigger_folded`:
/// case-insensitive and diacritic-insensitive, so "Kubernetes" and "kubernetes", or "Tāmaki" and
/// "Tamaki", collide on the same row.
extension String {
    var foldedForMatching: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }
}
