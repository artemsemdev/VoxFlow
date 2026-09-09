import Foundation
import GRDB

/// The `snippets` table: a trigger phrase that expands to a fixed body, optionally scoped to one
/// app (design Snippets tab). Synchronous and blocking like `DictationStore`.
public final class SnippetStore: Sendable {
    private let queue: DatabaseQueue

    public init(database: VoxFlowDatabase) { queue = database.queue }

    /// Throws `StorageError.duplicate(existingID:)` when a row with the same folded trigger already exists.
    @discardableResult
    public func insert(trigger: String, body: String, onlyIn: (bundleID: String, appName: String)? = nil) throws -> Snippet {
        if let existing = try find(trigger: trigger) { throw StorageError.duplicate(existingID: existing.id) }
        let createdAt = Date()
        let id: Int64 = try queue.write { db in
            try db.execute(
                sql: "INSERT INTO snippets (trigger, trigger_folded, body, only_in_bundle_id, only_in_app_name, uses, created_at) VALUES (?,?,?,?,?,0,?)",
                arguments: [trigger, trigger.foldedForMatching, body, onlyIn?.bundleID, onlyIn?.appName, createdAt.timeIntervalSince1970])
            return db.lastInsertedRowID
        }
        return Snippet(id: id, trigger: trigger, body: body, onlyInBundleID: onlyIn?.bundleID, onlyInAppName: onlyIn?.appName, uses: 0, createdAt: createdAt)
    }

    public func update(_ snippet: Snippet) throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE snippets SET trigger = ?, trigger_folded = ?, body = ?, only_in_bundle_id = ?, only_in_app_name = ?, uses = ? WHERE id = ?",
                arguments: [snippet.trigger, snippet.trigger.foldedForMatching, snippet.body, snippet.onlyInBundleID, snippet.onlyInAppName, snippet.uses, snippet.id])
        }
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
