import Foundation
import GRDB
import Synchronization

private final class RetainedDatabaseLifetime: Sendable {
    private let retention: Mutex<(@Sendable () -> Void)?>

    init(_ retention: @escaping @Sendable () -> Void) {
        self.retention = Mutex(retention)
    }

    func keepAlive() {
        retention.withLock { $0?() }
    }

    func release() {
        retention.withLock { $0 = nil }
    }
}

/// Owns the shared SQLite connection and every schema migration (design §5). One database file
/// backs dictation history plus the dictionary, snippets, and per-app style override tables.
public final class VoxFlowDatabase: Sendable {
    public let queue: DatabaseQueue
    private let retainedLifetime: RetainedDatabaseLifetime?

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoxFlow/voxflow.sqlite")
    }

    public convenience init(url: URL, configuration: Configuration) throws {
        try self.init(url: url, configuration: configuration, retainedLifetime: nil)
    }

    private init(url: URL, configuration: Configuration, retainedLifetime: RetainedDatabaseLifetime?) throws {
        self.retainedLifetime = retainedLifetime
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try Self.migrator.migrate(queue)
    }

    public convenience init(url: URL) throws {
        try self.init(url: url, configuration: Configuration())
    }

    /// Opens a database while retaining the supplied lifetime closure until the queue closes.
    /// This is useful for temporary file fixtures whose directory must outlive all queue users.
    public convenience init(url: URL, retaining lifetime: @escaping @Sendable () -> Void) throws {
        let retainedLifetime = RetainedDatabaseLifetime(lifetime)
        var configuration = Configuration()
        // GRDB retains the fallback through its connection configuration. If an explicit close
        // cannot complete during wrapper teardown, this keeps the fixture alive until GRDB's final
        // close_v2 and configuration release.
        configuration.prepareDatabase { [retainedLifetime] _ in retainedLifetime.keepAlive() }
        try self.init(url: url, configuration: configuration, retainedLifetime: retainedLifetime)
    }

    public static func inMemory() throws -> VoxFlowDatabase {
        try VoxFlowDatabase(queue: DatabaseQueue())
    }

    private init(queue: DatabaseQueue) throws {
        retainedLifetime = nil
        self.queue = queue
        try Self.migrator.migrate(queue)
    }

    deinit {
        guard let retainedLifetime else { return }
        // A successful synchronous close makes it safe to release a temporary fixture immediately.
        // On failure, the configuration-owned fallback keeps it alive through GRDB's close_v2.
        if (try? queue.close()) != nil {
            retainedLifetime.release()
        }
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
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE mcp_clients (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  name TEXT NOT NULL, path TEXT NOT NULL,
                  approved BOOLEAN NOT NULL DEFAULT 0,
                  first_seen DOUBLE NOT NULL, last_seen DOUBLE NOT NULL,
                  UNIQUE(name, path));
                """)
        }
        migrator.registerMigration("v4-history-annotations") { db in
            try db.alter(table: "dictations") { $0.add(column: "annotations", .blob) }
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
