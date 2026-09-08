import Foundation
import GRDB

/// History on SQLite (design §5). `keyProvider == nil` stores plaintext (Privacy toggle off).
///
/// Synchronous and blocking: every call does SQLite I/O, and `search`/`fetch` additionally run
/// AES-GCM over every candidate row, all on the calling thread. Call this off the main actor.
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
        var isNewlyCreated = false
        if let keyProvider {
            let historyKey = try keyProvider.historyKey()
            cipher = DictationCipher(key: historyKey.key)
            isNewlyCreated = historyKey.isNewlyCreated
        } else {
            cipher = nil
        }
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

        // A key provider that just generated (rather than re-derived/re-read) the key it handed back,
        // over a database that already has encrypted rows, means the original key material is gone —
        // regenerating would leave every existing row permanently undecryptable with no warning.
        if keyProvider != nil, isNewlyCreated {
            let encryptedCount = try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dictations WHERE encrypted = 1") ?? 0 }
            if encryptedCount > 0 { throw StorageError.keyLost }
        }
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

    /// Never throws because of a single row: a row that can't be decoded comes back with
    /// `isUnreadable = true` and empty text instead of failing the whole list (see `record(from:)`).
    public func fetch(limit: Int) throws -> [DictationRecord] {
        try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM dictations ORDER BY created_at DESC, id DESC LIMIT ?", arguments: [limit]) }
            .map(record(from:))
    }

    /// Case-insensitive substring match over decrypted text and raw transcript; blank query returns
    /// everything readable. Unreadable rows (see `fetch`) are skipped — there's no text to match.
    public func search(_ query: String) throws -> [DictationRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = try fetch(limit: Int.max)
        guard !needle.isEmpty else { return all }                 // a blank query lists everything, unreadable rows included
        return all.filter { !$0.isUnreadable }.filter { $0.text.lowercased().contains(needle) || $0.rawText.lowercased().contains(needle) }
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

    func textColumnForTesting(id: Int64) throws -> Data? {
        try queue.read { try Data.fetchOne($0, sql: "SELECT text FROM dictations WHERE id = ?", arguments: [id]) }
    }

    private func encode(_ text: String) throws -> Data { try cipher?.seal(text) ?? Data(text.utf8) }

    /// Per-row, never throwing: an encrypted row with no cipher available, or one whose `cipher.open`
    /// fails, comes back with empty text and `isUnreadable = true` rather than taking down the whole
    /// `fetch`/`search` call (C1) — the ordinary result of switching "Encrypt history at rest" off, or
    /// of a lost key (I2), must not turn History into a permanent error screen.
    private func record(from row: Row) -> DictationRecord {
        let encrypted: Bool = row["encrypted"]
        func decode(_ column: String) -> String? {
            let data: Data = row[column]
            if encrypted {
                guard let cipher else { return nil }
                return try? cipher.open(data)
            }
            return String(data: data, encoding: .utf8)
        }
        let text = decode("text"), rawText = decode("raw_text")
        let readable = text != nil && rawText != nil
        return DictationRecord(id: row["id"], text: readable ? text! : "", rawText: readable ? rawText! : "", appName: row["app_name"],
                               style: row["style"], language: row["language"], duration: row["duration"], words: row["words"],
                               createdAt: Date(timeIntervalSince1970: row["created_at"]), isUnreadable: !readable)
    }
}
