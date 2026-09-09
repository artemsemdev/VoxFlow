import Foundation
import GRDB
import VoxFlowCore

/// The `dictionary` table: proper nouns and terms Speech should recognize (design Dictionary tab).
/// Synchronous and blocking like `DictationStore` — call this off the main actor.
public final class DictionaryStore: Sendable {
    private let queue: DatabaseQueue

    public init(database: VoxFlowDatabase) { queue = database.queue }

    /// Throws `StorageError.duplicate(existingID:)` when a row with the same folded word already
    /// exists. The `find` is a fast pre-check; the `word_folded` `UNIQUE` column is the real
    /// enforcement, so a `SQLITE_CONSTRAINT_UNIQUE` from the write itself (e.g. a race between two
    /// inserts) is also caught and translated — callers never see a raw `GRDB.DatabaseError`.
    @discardableResult
    public func insert(word: String, soundsLike: String?, type: DictionaryEntryType, fixTyping: Bool, source: String = "user") throws -> DictionaryEntry {
        if let existing = try find(word: word) { throw StorageError.duplicate(existingID: existing.id) }
        let createdAt = Date()
        do {
            let id: Int64 = try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO dictionary (word, word_folded, sounds_like, type, fix_typing, source, uses, created_at) VALUES (?,?,?,?,?,?,0,?)",
                    arguments: [word, word.foldedForMatching, soundsLike, type.rawValue, fixTyping, source, createdAt.timeIntervalSince1970])
                return db.lastInsertedRowID
            }
            return DictionaryEntry(id: id, word: word, soundsLike: soundsLike, type: type, fixTyping: fixTyping, source: source, uses: 0, createdAt: createdAt)
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw try duplicateError(forFoldedWord: word.foldedForMatching, excluding: nil)
        }
    }

    /// Throws `StorageError.duplicate(existingID:)` when the edited word folds to a value another
    /// row already owns (a case/diacritic variant of the entry's own current value is not a
    /// collision, since `UPDATE` never conflicts with itself).
    public func update(_ entry: DictionaryEntry) throws {
        do {
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE dictionary SET word = ?, word_folded = ?, sounds_like = ?, type = ?, fix_typing = ?, source = ?, uses = ? WHERE id = ?",
                    arguments: [entry.word, entry.word.foldedForMatching, entry.soundsLike, entry.type.rawValue, entry.fixTyping, entry.source, entry.uses, entry.id])
            }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw try duplicateError(forFoldedWord: entry.word.foldedForMatching, excluding: entry.id)
        }
    }

    /// Looks up the row already holding `folded` (optionally excluding one id) to report in
    /// `StorageError.duplicate(existingID:)` after a `UNIQUE` violation.
    private func duplicateError(forFoldedWord folded: String, excluding id: Int64?) throws -> StorageError {
        let existingID: Int64? = try queue.read { db in
            if let id {
                try Int64.fetchOne(db, sql: "SELECT id FROM dictionary WHERE word_folded = ? AND id != ?", arguments: [folded, id])
            } else {
                try Int64.fetchOne(db, sql: "SELECT id FROM dictionary WHERE word_folded = ?", arguments: [folded])
            }
        }
        return .duplicate(existingID: existingID ?? id ?? 0)
    }

    public func delete(id: Int64) throws {
        try queue.write { try $0.execute(sql: "DELETE FROM dictionary WHERE id = ?", arguments: [id]) }
    }

    /// Alphabetical by folded word.
    public func all() throws -> [DictionaryEntry] {
        try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM dictionary ORDER BY word_folded ASC") }.map(Self.record(from:))
    }

    public func find(word: String) throws -> DictionaryEntry? {
        try queue.read { db in try Row.fetchOne(db, sql: "SELECT * FROM dictionary WHERE word_folded = ?", arguments: [word.foldedForMatching]) }.map(Self.record(from:))
    }

    /// Deletes every row whose `source` matches (e.g. `"contacts"`), leaving other sources (`"user"`) untouched.
    public func removeAll(source: String) throws {
        try queue.write { try $0.execute(sql: "DELETE FROM dictionary WHERE source = ?", arguments: [source]) }
    }

    /// Bumps `uses` for each dictionary entry whose folded word matches a folded whole word in
    /// `words`; a word occurring more than once increments its entry by that many.
    public func incrementUses(words: [String]) throws {
        var counts: [String: Int] = [:]
        for word in words { counts[word.foldedForMatching, default: 0] += 1 }
        guard !counts.isEmpty else { return }
        try queue.write { db in
            for (folded, count) in counts {
                try db.execute(sql: "UPDATE dictionary SET uses = uses + ? WHERE word_folded = ?", arguments: [count, folded])
            }
        }
    }

    /// The most-used words first, ties broken alphabetically, capped at `limit`.
    public func vocabulary(limit: Int) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT word FROM dictionary ORDER BY uses DESC, word_folded ASC LIMIT ?", arguments: [limit])
        }
    }

    private static func record(from row: Row) -> DictionaryEntry {
        DictionaryEntry(id: row["id"], word: row["word"], soundsLike: row["sounds_like"],
                        type: DictionaryEntryType(rawValue: row["type"]) ?? .term, fixTyping: row["fix_typing"],
                        source: row["source"], uses: row["uses"], createdAt: Date(timeIntervalSince1970: row["created_at"]))
    }
}
