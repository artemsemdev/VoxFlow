import CryptoKit
import Foundation
import Testing
@testable import VoxFlowStorage

struct FakeKeyProvider: HistoryKeyProviding {
    let key: SymmetricKey
    var isNew: Bool
    init(key: SymmetricKey = SymmetricKey(size: .bits256), isNew: Bool = false) {
        self.key = key
        self.isNew = isNew
    }
    func historyKey() throws -> HistoryKey { HistoryKey(key: key, isNewlyCreated: isNew) }
}

@Suite("DictationStore")
struct DictationStoreTests {
    func draft(_ text: String, at date: Date, app: String? = "Mail") -> DictationDraft {
        DictationDraft(text: text, rawText: text + " raw", appName: app, style: nil, language: "en", duration: 2.5, createdAt: date)
    }

    @Test("insert then fetch newest first; word count derived from text")
    func insertFetch() throws {
        let store = try DictationStore(inMemoryWith: nil)
        let older = try store.insert(draft("first one", at: Date(timeIntervalSince1970: 100)))
        let newer = try store.insert(draft("second one here", at: Date(timeIntervalSince1970: 200)))
        let all = try store.fetch(limit: 10)
        #expect(all.map(\.id) == [newer.id, older.id])
        #expect(all.first?.words == 3)
        #expect(all.first?.rawText == "second one here raw")
        #expect(try store.count() == 2)
    }

    @Test("encrypted rows are unreadable in SQL and transparent through the store")
    func encryption() throws {
        let store = try DictationStore(inMemoryWith: FakeKeyProvider())
        _ = try store.insert(draft("secret words", at: Date()))
        let raw = try store.textColumnForTesting(id: 1)
        #expect(raw != Data("secret words".utf8))
        #expect(try store.fetch(limit: 1).first?.text == "secret words")
    }

    @Test("search matches text or raw transcript, case-insensitive, after decryption")
    func search() throws {
        let store = try DictationStore(inMemoryWith: FakeKeyProvider())
        _ = try store.insert(draft("Quarterly numbers look fine", at: Date(timeIntervalSince1970: 1)))
        _ = try store.insert(DictationDraft(text: "clean", rawText: "um clean NUMBERS", appName: nil, style: nil, language: nil, duration: 1, createdAt: Date(timeIntervalSince1970: 2)))
        _ = try store.insert(draft("unrelated", at: Date(timeIntervalSince1970: 3)))
        #expect(try store.search("numbers").map(\.text) == ["clean", "Quarterly numbers look fine"])
        #expect(try store.search("  ").count == 3)
    }

    @Test("delete one, delete all, delete older than a cutoff")
    func deletes() throws {
        let store = try DictationStore(inMemoryWith: nil)
        let a = try store.insert(draft("a", at: Date(timeIntervalSince1970: 10)))
        _ = try store.insert(draft("b", at: Date(timeIntervalSince1970: 20)))
        _ = try store.insert(draft("c", at: Date(timeIntervalSince1970: 30)))
        try store.delete(id: a.id)
        #expect(try store.count() == 2)
        #expect(try store.deleteOlderThan(Date(timeIntervalSince1970: 25)) == 1)
        #expect(try store.fetch(limit: 10).map(\.text) == ["c"])
        try store.deleteAll()
        #expect(try store.count() == 0)
    }

    @Test("a file-backed store persists across instances")
    func persistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voxflow.sqlite")
        _ = try DictationStore(databaseURL: url, keyProvider: nil).insert(draft("kept", at: Date()))
        #expect(try DictationStore(databaseURL: url, keyProvider: nil).fetch(limit: 1).first?.text == "kept")
    }

    @Test("fetch never fails on an unreadable row: reopening without the key flags encrypted rows, plaintext still reads")
    func unreadableRowsDoNotBreakFetch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voxflow.sqlite")

        let keyed = try DictationStore(databaseURL: url, keyProvider: FakeKeyProvider())
        _ = try keyed.insert(draft("first secret", at: Date(timeIntervalSince1970: 1)))
        _ = try keyed.insert(draft("second secret", at: Date(timeIntervalSince1970: 2)))

        let reopened = try DictationStore(databaseURL: url, keyProvider: nil)
        let all = try reopened.fetch(limit: 10)
        #expect(all.count == 2)
        #expect(all.allSatisfy { $0.isUnreadable })
        #expect(all.allSatisfy { $0.text.isEmpty && $0.rawText.isEmpty })
        #expect(try reopened.search("secret").isEmpty)   // unreadable rows never surface in search

        _ = try reopened.insert(draft("plain text after", at: Date(timeIntervalSince1970: 3)))
        let afterInsert = try reopened.fetch(limit: 10)
        #expect(afterInsert.count == 3)
        #expect(afterInsert.filter(\.isUnreadable).count == 2)
        let readable = afterInsert.first { !$0.isUnreadable }
        #expect(readable?.text == "plain text after")
        #expect(try reopened.search("plain").map(\.text) == ["plain text after"])
    }

    @Test("stats sums count/words/duration since a cutoff; zero for an empty store")
    func statsSinceCutoff() throws {
        let store = try DictationStore(inMemoryWith: nil)
        _ = try store.insert(draft("one two", at: Date(timeIntervalSince1970: 50)))        // before the cutoff
        _ = try store.insert(DictationDraft(text: "three four five", rawText: "x", appName: nil, style: nil, language: nil, duration: 3, createdAt: Date(timeIntervalSince1970: 100)))
        _ = try store.insert(DictationDraft(text: "six", rawText: "x", appName: nil, style: nil, language: nil, duration: 2, createdAt: Date(timeIntervalSince1970: 200)))

        let stats = try store.stats(since: Date(timeIntervalSince1970: 100))
        #expect(stats == DictationStats(count: 2, words: 4, duration: 5))
        #expect(try store.stats(since: Date(timeIntervalSince1970: 1000)) == DictationStats(count: 0, words: 0, duration: 0))
    }

    @Test("stats still counts an unreadable (encrypted, key unavailable) row: words/duration are plain columns")
    func statsCountsUnreadableRows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voxflow.sqlite")

        let keyed = try DictationStore(databaseURL: url, keyProvider: FakeKeyProvider())
        _ = try keyed.insert(draft("first secret", at: Date(timeIntervalSince1970: 10)))

        let reopened = try DictationStore(databaseURL: url, keyProvider: nil)
        let all = try reopened.fetch(limit: 10)
        #expect(all.first?.isUnreadable == true)
        #expect(try reopened.stats(since: Date(timeIntervalSince1970: 0)) == DictationStats(count: 1, words: 2, duration: 2.5))
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test("wordsPerDay buckets by local calendar day, zero-filled, oldest first, across a midnight boundary")
    func wordsPerDayBuckets() throws {
        let calendar = Self.utcCalendar()
        let store = try DictationStore(inMemoryWith: nil)

        let lateAug31 = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 23, minute: 30))!
        let earlySep1 = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 0, minute: 30))!
        let midSep1 = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 12))!
        let sep2 = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 9))!
        let endingAt = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 18))!

        _ = try store.insert(draft("a b", at: lateAug31, app: nil))                 // Aug 31
        _ = try store.insert(draft("c d e", at: earlySep1, app: nil))               // Sep 1
        _ = try store.insert(draft("f", at: midSep1, app: nil))                     // Sep 1
        _ = try store.insert(draft("g h", at: sep2, app: nil))                      // Sep 2

        let result = try store.wordsPerDay(days: 4, endingAt: endingAt, calendar: calendar)
        #expect(result.map(\.words) == [0, 2, 4, 2])   // Aug 30 (0), Aug 31 (2), Sep 1 (4), Sep 2 (2)
        #expect(result.count == 4)
        #expect(calendar.isDate(result.last!.date, inSameDayAs: sep2))
        #expect(calendar.isDate(result.first!.date, inSameDayAs: calendar.date(from: DateComponents(year: 2026, month: 8, day: 30))!))
    }

    @Test("streak counts consecutive days ending today with a dictation; a gap stops it; 0 with none today")
    func streakConsecutiveDays() throws {
        let calendar = Self.utcCalendar()
        let store = try DictationStore(inMemoryWith: nil)

        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 10))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 10))!
        let twoDaysAgo = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 10))!
        let beforeTheGap = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 10))!

        _ = try store.insert(draft("a", at: today, app: nil))
        _ = try store.insert(draft("b", at: yesterday, app: nil))
        _ = try store.insert(draft("c", at: twoDaysAgo, app: nil))
        _ = try store.insert(draft("d", at: beforeTheGap, app: nil))

        #expect(try store.streak(endingAt: today, calendar: calendar) == 3)

        let empty = try DictationStore(inMemoryWith: nil)
        #expect(try empty.streak(endingAt: today, calendar: calendar) == 0)

        let onlyYesterday = try DictationStore(inMemoryWith: nil)
        _ = try onlyYesterday.insert(draft("a", at: yesterday, app: nil))
        #expect(try onlyYesterday.streak(endingAt: today, calendar: calendar) == 0)   // nothing today: no streak
    }

    @Test("streak is bounded to streakLookbackDays: a row far outside the window doesn't affect the result (M3)")
    func streakIsBoundedToLookbackWindow() throws {
        let calendar = Self.utcCalendar()
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 10))!
        let store = try DictationStore(inMemoryWith: nil)
        _ = try store.insert(draft("today", at: today, app: nil))
        // Well outside the lookback window — the unbounded query used to pull this into memory on
        // every `streak()` call; it must have no bearing on today's (unbroken, 1-day) streak.
        let longAgo = calendar.date(byAdding: .day, value: -(DictationStore.streakLookbackDays + 50), to: today)!
        _ = try store.insert(draft("long ago", at: longAgo, app: nil))

        #expect(try store.streak(endingAt: today, calendar: calendar) == 1)
    }

    @Test("a key provider reporting a freshly-created key over an already-encrypted database throws keyLost; the existing key still works")
    func lostKeyIsDetected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voxflow.sqlite")
        let sharedKey = SymmetricKey(size: .bits256)

        _ = try DictationStore(databaseURL: url, keyProvider: FakeKeyProvider(key: sharedKey)).insert(draft("secret", at: Date()))

        #expect(throws: StorageError.keyLost) {
            _ = try DictationStore(databaseURL: url, keyProvider: FakeKeyProvider(key: SymmetricKey(size: .bits256), isNew: true))
        }

        let reopened = try DictationStore(databaseURL: url, keyProvider: FakeKeyProvider(key: sharedKey, isNew: false))
        #expect(try reopened.count() == 1)
        #expect(try reopened.fetch(limit: 1).first?.text == "secret")
    }

    // MARK: updateStyled (Re-style, MW-02s)

    @Test("updateStyled round-trips through fetch on an encrypted store: new text/style/words, rawText and createdAt untouched")
    func updateStyledRoundTripsOnEncryptedStore() throws {
        let store = try DictationStore(inMemoryWith: FakeKeyProvider())
        let original = try store.insert(draft("um send this over", at: Date(timeIntervalSince1970: 42)))
        #expect(original.style == nil)

        let updated = try store.updateStyled(id: original.id, text: "Please send this over.", style: "formal")

        #expect(updated?.id == original.id)
        #expect(updated?.text == "Please send this over.")
        #expect(updated?.style == "formal")
        #expect(updated?.words == 4)
        #expect(updated?.rawText == original.rawText)
        #expect(updated?.createdAt == original.createdAt)

        let refetched = try store.fetch(limit: 10).first
        #expect(refetched?.text == "Please send this over.")
        #expect(refetched?.style == "formal")
        #expect(refetched?.words == 4)
        #expect(refetched?.rawText == original.rawText)
    }

    @Test("updateStyled on an unknown id returns nil and touches nothing")
    func updateStyledUnknownIdReturnsNil() throws {
        let store = try DictationStore(inMemoryWith: nil)
        _ = try store.insert(draft("a", at: Date(timeIntervalSince1970: 1)))

        let result = try store.updateStyled(id: 999, text: "new text", style: "casual")

        #expect(result == nil)
        #expect(try store.fetch(limit: 10).map(\.text) == ["a"])
    }

    @Test("updateStyled on one row does not touch an unreadable (key-lost) row")
    func updateStyledLeavesUnreadableRowsUntouched() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voxflow.sqlite")

        let keyed = try DictationStore(databaseURL: url, keyProvider: FakeKeyProvider())
        let encryptedRow = try keyed.insert(draft("secret one", at: Date(timeIntervalSince1970: 1)))

        // Reopen without a cipher: `encryptedRow` is now unreadable, but plaintext inserts on this
        // same (unencrypted) connection stay readable.
        let reopened = try DictationStore(databaseURL: url, keyProvider: nil)
        let plainRow = try reopened.insert(draft("plain two", at: Date(timeIntervalSince1970: 2)))

        let updated = try reopened.updateStyled(id: plainRow.id, text: "Plain two, updated.", style: "casual")
        #expect(updated?.text == "Plain two, updated.")

        let all = try reopened.fetch(limit: 10)
        let untouched = try #require(all.first { $0.id == encryptedRow.id })
        #expect(untouched.isUnreadable == true)
        #expect(untouched.text.isEmpty)
    }
}
