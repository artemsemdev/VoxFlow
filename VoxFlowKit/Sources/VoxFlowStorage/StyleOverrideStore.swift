import Foundation
import GRDB
import VoxFlowCore

/// The `app_style_overrides` table: a per-app rewrite tone that overrides the global default
/// (design Styles tab). Synchronous and blocking like `DictationStore`.
public final class StyleOverrideStore: Sendable {
    private let queue: DatabaseQueue

    public init(database: VoxFlowDatabase) { queue = database.queue }

    /// Upsert: replaces the app name and style if `bundleID` already has an override.
    public func set(bundleID: String, appName: String, style: TextStyle) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_style_overrides (bundle_id, app_name, style) VALUES (?,?,?)
                    ON CONFLICT(bundle_id) DO UPDATE SET app_name = excluded.app_name, style = excluded.style
                    """,
                arguments: [bundleID, appName, style.rawValue])
        }
    }

    public func remove(bundleID: String) throws {
        try queue.write { try $0.execute(sql: "DELETE FROM app_style_overrides WHERE bundle_id = ?", arguments: [bundleID]) }
    }

    /// By app name.
    public func all() throws -> [StyleOverride] {
        try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM app_style_overrides ORDER BY app_name ASC") }.map(Self.record(from:))
    }

    public func style(for bundleID: String) throws -> TextStyle? {
        try queue.read { db in try String.fetchOne(db, sql: "SELECT style FROM app_style_overrides WHERE bundle_id = ?", arguments: [bundleID]) }
            .flatMap(TextStyle.init(rawValue:))
    }

    private static func record(from row: Row) -> StyleOverride {
        StyleOverride(bundleID: row["bundle_id"], appName: row["app_name"], style: TextStyle(rawValue: row["style"]) ?? .default)
    }
}
