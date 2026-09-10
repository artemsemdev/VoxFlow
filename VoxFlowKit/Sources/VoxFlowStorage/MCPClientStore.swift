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
    /// with `approved = false`, `firstSeen == lastSeen == now`; a repeat sighting updates only
    /// `lastSeen`, in place, rather than creating a duplicate row.
    ///
    /// Task 2 review ruling (I6): this used to be `insertOrTouch(name:path:approved:now:)`, an
    /// upsert that always overwrote `approved` with whatever the caller passed. The realistic
    /// "record every connection" caller has no correct value to pass: `approved: false` would
    /// silently de-approve every previously-approved client on its next connection, and
    /// `approved: true` would silently re-approve a client someone had just revoked. A
    /// security-relevant flag must not be a mandatory parameter of "I saw this client" — so
    /// recording a sighting and approving are now two separate calls, and only `approve` ever sets
    /// the flag.
    @discardableResult
    public func recordSighting(name: String, path: String, now: Date) throws -> MCPClientRecord {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO mcp_clients (name, path, approved, first_seen, last_seen) VALUES (?,?,0,?,?)
                    ON CONFLICT(name, path) DO UPDATE SET last_seen = excluded.last_seen
                    """,
                arguments: [name, path, now.timeIntervalSince1970, now.timeIntervalSince1970])
            return try Self.fetch(db, name: name, path: path)
        }
    }

    /// Marks `(name, path)` approved (ST-06a "Always allow"), inserting the row first if this is
    /// the client's first sighting. Also touches `lastSeen`, so an approval doubles as a sighting.
    @discardableResult
    public func approve(name: String, path: String, now: Date) throws -> MCPClientRecord {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO mcp_clients (name, path, approved, first_seen, last_seen) VALUES (?,?,1,?,?)
                    ON CONFLICT(name, path) DO UPDATE SET approved = 1, last_seen = excluded.last_seen
                    """,
                arguments: [name, path, now.timeIntervalSince1970, now.timeIntervalSince1970])
            return try Self.fetch(db, name: name, path: path)
        }
    }

    private static func fetch(_ db: Database, name: String, path: String) throws -> MCPClientRecord {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM mcp_clients WHERE name = ? AND path = ?", arguments: [name, path]) else {
            throw StorageError.corruptRow
        }
        return record(from: row)
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
