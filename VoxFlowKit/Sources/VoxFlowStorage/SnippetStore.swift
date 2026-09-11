import Foundation
import GRDB

/// The `snippets` table: a trigger phrase that expands to a fixed body, optionally scoped to one
/// app (design Snippets tab). Synchronous and blocking like `DictationStore`.
public final class SnippetStore: Sendable {
    private let database: VoxFlowDatabase
    private let queue: DatabaseQueue

    public init(database: VoxFlowDatabase) {
        self.database = database
        queue = database.queue
    }

    /// Throws `StorageError.duplicate(existingID:)` when a row with the same folded trigger already
    /// exists. The `find` is a fast pre-check; the `trigger_folded` `UNIQUE` column is the real
    /// enforcement, so a `SQLITE_CONSTRAINT_UNIQUE` from the write itself (e.g. a race between two
    /// inserts) is also caught and translated — callers never see a raw `GRDB.DatabaseError`.
    @discardableResult
    public func insert(trigger: String, body: String, onlyIn: (bundleID: String, appName: String)? = nil) throws -> Snippet {
        if let existing = try find(trigger: trigger) { throw StorageError.duplicate(existingID: existing.id) }
        let createdAt = Date()
        do {
            let id: Int64 = try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO snippets (trigger, trigger_folded, body, only_in_bundle_id, only_in_app_name, uses, created_at) VALUES (?,?,?,?,?,0,?)",
                    arguments: [trigger, trigger.foldedForMatching, body, onlyIn?.bundleID, onlyIn?.appName, createdAt.timeIntervalSince1970])
                return db.lastInsertedRowID
            }
            return Snippet(id: id, trigger: trigger, body: body, onlyInBundleID: onlyIn?.bundleID, onlyInAppName: onlyIn?.appName, uses: 0, createdAt: createdAt)
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw try duplicateError(forFoldedTrigger: trigger.foldedForMatching, excluding: nil)
        }
    }

    /// Throws `StorageError.duplicate(existingID:)` when the edited trigger folds to a value
    /// another row already owns (a case/diacritic variant of the snippet's own current value is
    /// not a collision, since `UPDATE` never conflicts with itself).
    public func update(_ snippet: Snippet) throws {
        do {
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE snippets SET trigger = ?, trigger_folded = ?, body = ?, only_in_bundle_id = ?, only_in_app_name = ?, uses = ? WHERE id = ?",
                    arguments: [snippet.trigger, snippet.trigger.foldedForMatching, snippet.body, snippet.onlyInBundleID, snippet.onlyInAppName, snippet.uses, snippet.id])
            }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw try duplicateError(forFoldedTrigger: snippet.trigger.foldedForMatching, excluding: snippet.id)
        }
    }

    /// Looks up the row already holding `folded` (optionally excluding one id) to report in
    /// `StorageError.duplicate(existingID:)` after a `UNIQUE` violation.
    private func duplicateError(forFoldedTrigger folded: String, excluding id: Int64?) throws -> StorageError {
        let existingID: Int64? = try queue.read { db in
            if let id {
                try Int64.fetchOne(db, sql: "SELECT id FROM snippets WHERE trigger_folded = ? AND id != ?", arguments: [folded, id])
            } else {
                try Int64.fetchOne(db, sql: "SELECT id FROM snippets WHERE trigger_folded = ?", arguments: [folded])
            }
        }
        return .duplicate(existingID: existingID ?? id ?? 0)
    }

    public func delete(id: Int64) throws {
        try queue.write { try $0.execute(sql: "DELETE FROM snippets WHERE id = ?", arguments: [id]) }
    }

    /// Most-used first, ties broken alphabetically by folded trigger.
    public func all() throws -> [Snippet] {
        try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM snippets ORDER BY uses DESC, trigger_folded ASC") }.map(Self.record(from:))
    }

    public func find(trigger: String) throws -> Snippet? {
        try queue.read { db in try Row.fetchOne(db, sql: "SELECT * FROM snippets WHERE trigger_folded = ?", arguments: [trigger.foldedForMatching]) }.map(Self.record(from:))
    }

    public func incrementUses(id: Int64) throws {
        try queue.write { try $0.execute(sql: "UPDATE snippets SET uses = uses + 1 WHERE id = ?", arguments: [id]) }
    }

    private static func record(from row: Row) -> Snippet {
        Snippet(id: row["id"], trigger: row["trigger"], body: row["body"], onlyInBundleID: row["only_in_bundle_id"],
                onlyInAppName: row["only_in_app_name"], uses: row["uses"], createdAt: Date(timeIntervalSince1970: row["created_at"]))
    }
}
