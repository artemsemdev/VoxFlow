import Foundation
import GRDB
import VoxFlowCore

/// The `mcp_clients` table: apps that have connected to the loopback MCP server (design ST-06
/// "Connected clients"). Synchronous and blocking like `DictionaryStore` — call this off the main
/// actor.
public final class MCPClientStore: Sendable {
    private let queue: DatabaseQueue

    public init(database: VoxFlowDatabase) { queue = database.queue }

    /// Upsert keyed on `(name, path)` (never pid — ruling 5): a first sighting inserts a new row
    /// with `firstSeen == lastSeen == now`; a repeat sighting updates `approved` and `lastSeen`
    /// in place, leaving `firstSeen` untouched, rather than creating a duplicate row.
    @discardableResult
    public func insertOrTouch(name: String, path: String, approved: Bool, now: Date) throws -> MCPClientRecord {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO mcp_clients (name, path, approved, first_seen, last_seen) VALUES (?,?,?,?,?)
                    ON CONFLICT(name, path) DO UPDATE SET approved = excluded.approved, last_seen = excluded.last_seen
                    """,
                arguments: [name, path, approved, now.timeIntervalSince1970, now.timeIntervalSince1970])
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM mcp_clients WHERE name = ? AND path = ?", arguments: [name, path]) else {
                throw StorageError.corruptRow
            }
            return Self.record(from: row)
        }
    }

    /// Most recently seen first.
    public func all() throws -> [MCPClientRecord] {
        try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM mcp_clients ORDER BY last_seen DESC") }.map(Self.record(from:))
    }

    public func revoke(id: Int64) throws {
        try queue.write { try $0.execute(sql: "DELETE FROM mcp_clients WHERE id = ?", arguments: [id]) }
    }

    public func revokeAll() throws {
        try queue.write { try $0.execute(sql: "DELETE FROM mcp_clients") }
    }

    private static func record(from row: Row) -> MCPClientRecord {
        MCPClientRecord(id: row["id"], name: row["name"], path: row["path"], approved: row["approved"],
                        firstSeen: Date(timeIntervalSince1970: row["first_seen"]), lastSeen: Date(timeIntervalSince1970: row["last_seen"]))
    }
}
