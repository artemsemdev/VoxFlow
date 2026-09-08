import Foundation
import GRDB

/// History on SQLite (design §5). `keyProvider == nil` stores plaintext (Privacy toggle off).
public final class DictationStore: Sendable {
    private let queue: DatabaseQueue
    private let cipher: DictationCipher?

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoxFlow/voxflow.sqlite")
    }

    public convenience init(databaseURL: URL, keyProvider: (any HistoryKeyProviding)?) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(queue: DatabaseQueue(path: databaseURL.path), keyProvider: keyProvider)
    }

    public convenience init(inMemoryWith keyProvider: (any HistoryKeyProviding)?) throws {
        try self.init(queue: DatabaseQueue(), keyProvider: keyProvider)
    }

    private init(queue: DatabaseQueue, keyProvider: (any HistoryKeyProviding)?) throws {
        self.queue = queue
        cipher = try keyProvider.map { DictationCipher(key: try $0.historyKey()) }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE dictations (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, created_at DOUBLE NOT NULL, app_name TEXT, style TEXT, language TEXT,
                  duration DOUBLE NOT NULL, words INTEGER NOT NULL, encrypted BOOLEAN NOT NULL, text BLOB NOT NULL, raw_text BLOB NOT NULL);
                CREATE INDEX dictations_created_at ON dictations(created_at);
                """)
        }
        try migrator.migrate(queue)
    }

    @discardableResult
    public func insert(_ draft: DictationDraft) throws -> DictationRecord {
        let words = DictationRecord.wordCount(draft.text)
        let text = try encode(draft.text), raw = try encode(draft.rawText)
        let id: Int64 = try queue.write { db in
            try db.execute(sql: "INSERT INTO dictations (created_at, app_name, style, language, duration, words, encrypted, text, raw_text) VALUES (?,?,?,?,?,?,?,?,?)",
                           arguments: [draft.createdAt.timeIntervalSince1970, draft.appName, draft.style, draft.language, draft.duration, words, cipher != nil, text, raw])
            return db.lastInsertedRowID
        }
        return DictationRecord(id: id, text: draft.text, rawText: draft.rawText, appName: draft.appName, style: draft.style,
                               language: draft.language, duration: draft.duration, words: words, createdAt: draft.createdAt)
    }

    public func fetch(limit: Int) throws -> [DictationRecord] {
        try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM dictations ORDER BY created_at DESC, id DESC LIMIT ?", arguments: [limit]) }
            .map(record(from:))
    }

    /// Case-insensitive substring match over decrypted text and raw transcript; blank query returns everything.
    public func search(_ query: String) throws -> [DictationRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = try fetch(limit: Int.max)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.text.lowercased().contains(needle) || $0.rawText.lowercased().contains(needle) }
    }

    public func count() throws -> Int { try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dictations") ?? 0 } }
    public func delete(id: Int64) throws { try queue.write { try $0.execute(sql: "DELETE FROM dictations WHERE id = ?", arguments: [id]) } }
    public func deleteAll() throws { try queue.write { try $0.execute(sql: "DELETE FROM dictations") } }

    @discardableResult
    public func deleteOlderThan(_ cutoff: Date) throws -> Int {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM dictations WHERE created_at < ?", arguments: [cutoff.timeIntervalSince1970])
            return db.changesCount
        }
    }

    func rawTextColumnForTesting(id: Int64) throws -> Data? {
        try queue.read { try Data.fetchOne($0, sql: "SELECT text FROM dictations WHERE id = ?", arguments: [id]) }
    }

    private func encode(_ text: String) throws -> Data { try cipher?.seal(text) ?? Data(text.utf8) }

    private func record(from row: Row) throws -> DictationRecord {
        let encrypted: Bool = row["encrypted"]
        func decode(_ column: String) throws -> String {
            let data: Data = row[column]
            if encrypted { guard let cipher else { throw StorageError.corruptRow }; return try cipher.open(data) }
            guard let s = String(data: data, encoding: .utf8) else { throw StorageError.corruptRow }
            return s
        }
        return DictationRecord(id: row["id"], text: try decode("text"), rawText: try decode("raw_text"), appName: row["app_name"],
                               style: row["style"], language: row["language"], duration: row["duration"], words: row["words"],
                               createdAt: Date(timeIntervalSince1970: row["created_at"]))
    }
}
