import Foundation
import GRDB

/// Home page stats (design MW-01, ruling 1): `count`/`words`/`duration` of dictations since a cutoff.
public struct DictationStats: Sendable, Equatable {
    public var count: Int
    public var words: Int
    public var duration: TimeInterval
    public init(count: Int, words: Int, duration: TimeInterval) {
        self.count = count
        self.words = words
        self.duration = duration
    }
}

/// One bucket of `DictationStore.wordsPerDay` — a local calendar day and its word total (0 when
/// there was no dictation that day).
public struct DayWords: Sendable, Equatable {
    public var date: Date
    public var words: Int
    public init(date: Date, words: Int) {
        self.date = date
        self.words = words
    }
}

/// History on SQLite (design §5). `keyProvider == nil` stores plaintext (Privacy toggle off).
///
/// Synchronous and blocking: every call does SQLite I/O, and `search`/`fetch` additionally run
/// AES-GCM over every candidate row, all on the calling thread. Call this off the main actor.
public final class DictationStore: Sendable {
    private let queue: DatabaseQueue
    private let cipher: DictationCipher?

    public static var defaultURL: URL { VoxFlowDatabase.defaultURL }

    /// M3: how far back `streak(endingAt:calendar:)` looks. The unbounded query used to pull every
    /// row ever written into memory on every `refresh()` (every Home navigation and every history
    /// change) just to test for a break in the last few days' worth of dictations. A genuine streak
    /// longer than this many consecutive days is effectively unreachable, so capping the lookback
    /// trades that edge case for a query that can never grow with the whole table's history.
    public static let streakLookbackDays = 400

    public convenience init(databaseURL: URL, keyProvider: (any HistoryKeyProviding)?) throws {
        try self.init(database: VoxFlowDatabase(url: databaseURL), keyProvider: keyProvider)
    }

    public convenience init(inMemoryWith keyProvider: (any HistoryKeyProviding)?) throws {
        try self.init(database: VoxFlowDatabase.inMemory(), keyProvider: keyProvider)
    }

    public init(database: VoxFlowDatabase, keyProvider: (any HistoryKeyProviding)?) throws {
        self.queue = database.queue
        var isNewlyCreated = false
        if let keyProvider {
            let historyKey = try keyProvider.historyKey()
            cipher = DictationCipher(key: historyKey.key)
            isNewlyCreated = historyKey.isNewlyCreated
        } else {
            cipher = nil
        }

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

    /// Home page "Words today" / "Dictations" / "Speaking pace" (design ruling 1). `words`/`duration`
    /// are plain columns (unlike `text`/`raw_text`), so an unreadable/encrypted row still counts.
    public func stats(since: Date) throws -> DictationStats {
        try queue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS count, COALESCE(SUM(words), 0) AS words, COALESCE(SUM(duration), 0) AS duration
                FROM dictations WHERE created_at >= ?
                """, arguments: [since.timeIntervalSince1970]) else {
                return DictationStats(count: 0, words: 0, duration: 0)
            }
            return DictationStats(count: row["count"], words: row["words"], duration: row["duration"])
        }
    }

    /// "This week" chart (design ruling 1): exactly `days` entries, oldest first, zero-filled,
    /// bucketed by `calendar`'s local day — the last entry is `endingAt`'s day.
    public func wordsPerDay(days: Int, endingAt: Date, calendar: Calendar) throws -> [DayWords] {
        guard days > 0 else { return [] }
        let endDay = calendar.startOfDay(for: endingAt)
        guard let startDay = calendar.date(byAdding: .day, value: -(days - 1), to: endDay),
              let rangeEnd = calendar.date(byAdding: .day, value: 1, to: endDay) else { return [] }
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT created_at, words FROM dictations WHERE created_at >= ? AND created_at < ?",
                             arguments: [startDay.timeIntervalSince1970, rangeEnd.timeIntervalSince1970])
        }
        var buckets: [Date: Int] = [:]
        for row in rows {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: row["created_at"]))
            buckets[day, default: 0] += (row["words"] as Int)
        }
        return (0..<days).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: startDay).map { DayWords(date: $0, words: buckets[$0] ?? 0) }
        }
    }

    /// Consecutive local calendar days ending at `endingAt`'s day with at least one dictation; 0 when
    /// there's none today (design ruling 1 — "12-day streak", hidden when 0).
    public func streak(endingAt: Date, calendar: Calendar) throws -> Int {
        let today = calendar.startOfDay(for: endingAt)
        guard let rangeEnd = calendar.date(byAdding: .day, value: 1, to: today) else { return 0 }
        // M3: bounded to `streakLookbackDays` — see that constant's doc comment.
        let rangeStart = calendar.date(byAdding: .day, value: -Self.streakLookbackDays, to: today) ?? .distantPast
        let timestamps = try queue.read { db in
            try Double.fetchAll(db, sql: "SELECT created_at FROM dictations WHERE created_at >= ? AND created_at < ?",
                                arguments: [rangeStart.timeIntervalSince1970, rangeEnd.timeIntervalSince1970])
        }
        let daysWithDictation = Set(timestamps.map { calendar.startOfDay(for: Date(timeIntervalSince1970: $0)) })
        var streak = 0
        var day = today
        while daysWithDictation.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    /// Re-style: replaces the inserted text and its style, recomputing `words`; `raw_text` and
    /// `created_at` are untouched. Returns nil when the row no longer exists.
    public func updateStyled(id: Int64, text: String, style: String) throws -> DictationRecord? {
        let words = DictationRecord.wordCount(text)
        let encoded = try encode(text)
        let changed = try queue.write { db in
            try db.execute(sql: "UPDATE dictations SET text = ?, style = ?, words = ?, encrypted = ? WHERE id = ?",
                           arguments: [encoded, style, words, cipher != nil, id])
            return db.changesCount
        }
        guard changed > 0 else { return nil }
        return try queue.read { db in try Row.fetchOne(db, sql: "SELECT * FROM dictations WHERE id = ?", arguments: [id]) }.map(record(from:))
    }

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
