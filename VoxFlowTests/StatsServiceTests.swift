import CryptoKit
import Foundation
import Synchronization
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

/// Mirrors `AppServices`' `HistorySavedSink` — the `Mutex`-boxed weak-attach pattern
/// `HistoryWriter.save`'s `@Sendable` `onSaved` needs to safely reach the main-actor
/// `HistoryService` from its detached insert task (see C1).
private final class TestHistorySavedSink: Sendable {
    private struct WeakBox { weak var service: HistoryService? }
    private let box = Mutex(WeakBox(service: nil))
    func attach(_ service: HistoryService) { box.withLock { $0.service = service } }
    func notify() async {
        await Task { @MainActor in self.box.withLock { $0.service }?.notifyChanged() }.value
    }
}

private struct FakeHistoryKeyProvider: HistoryKeyProviding {
    let key: SymmetricKey
    var isNew: Bool
    init(key: SymmetricKey = SymmetricKey(size: .bits256), isNew: Bool = false) {
        self.key = key
        self.isNew = isNew
    }
    func historyKey() throws -> HistoryKey { HistoryKey(key: key, isNewlyCreated: isNew) }
}

@Suite("HomeStats")
struct HomeStatsTests {
    @Test("minutesSaved: words at 40 wpm minus minutes actually spent, floored at 0")
    func minutesSaved() {
        #expect(HomeStats.minutesSaved(words: 800, minutes: 5) == 15)     // 20 min typed − 5 min spoken
        #expect(HomeStats.minutesSaved(words: 40, minutes: 10) == 0)      // 1 − 10: floored at 0, never negative
        #expect(HomeStats.minutesSaved(words: 0, minutes: 0) == 0)
    }

    @Test("pace: words ÷ minutes; nil ('—') when there was no dictation")
    func pace() {
        #expect(HomeStats.pace(words: 300, minutes: 3) == 100)
        #expect(HomeStats.pace(words: 0, minutes: 0) == nil)
        #expect(HomeStats.pace(words: 10, minutes: 0) == nil)
    }
}

@Suite("Greeting")
struct GreetingTests {
    @Test("text follows the hour boundaries: <12 morning, <18 afternoon, else evening", arguments: [
        (0, "Good morning"), (11, "Good morning"),
        (12, "Good afternoon"), (17, "Good afternoon"),
        (18, "Good evening"), (23, "Good evening"),
    ])
    func text(hour: Int, expected: String) {
        #expect(Greeting.text(hour: hour) == expected)
    }

    @Test("dateLine: long weekday + month day; streak suffix from 2 up, hidden below that")
    func dateLine() {
        let locale = Locale(identifier: "en_US")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current   // matches `Greeting.dateLine`'s own formatter (system time zone)
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7))!

        #expect(Greeting.dateLine(date: date, streak: 0, locale: locale) == "Monday, September 7")
        #expect(Greeting.dateLine(date: date, streak: 1, locale: locale) == "Monday, September 7")
        #expect(Greeting.dateLine(date: date, streak: 12, locale: locale) == "Monday, September 7 · 12-day streak")
    }

    @Test("firstName: the first token; the whole string when there's no space")
    func firstName() {
        #expect(Greeting.firstName(from: "Artem Semenov") == "Artem")
        #expect(Greeting.firstName(from: "Cher") == "Cher")
    }
}

@Suite("StatsService")
@MainActor
struct StatsServiceTests {
    /// Opens a real (unencrypted, no-retention-purge) `HistoryService` over a seeded temp database,
    /// mirroring `HistoryServiceTests`' harness.
    func makeHistory(dir: TemporaryDirectory) -> HistoryService {
        let settings = DictationSettings(store: InMemoryKeyValueStore())
        settings.retentionDays = 0
        settings.encryptHistory = false
        return HistoryService(url: dir.file("voxflow.sqlite"), settings: settings,
                              keyProvider: { FakeHistoryKeyProvider() }, clock: FakeClock())
    }

    func draft(_ text: String, at date: Date, app: String? = "Mail", duration: TimeInterval = 1) -> DictationDraft {
        DictationDraft(text: text, rawText: text + " raw", appName: app, style: nil, language: "en", duration: duration, createdAt: date)
    }

    /// Bounded cooperative wait for `StatsService`'s `onChange`-triggered refresh (an unstructured
    /// `Task`, so genuinely asynchronous relative to the write that fired it) — not a sleep, and
    /// capped so a wiring regression fails the test instead of hanging it.
    func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    @Test("refresh derives today/week/weekTotal/streak/recent from the store")
    func refreshComputesStats() async throws {
        let dir = TemporaryDirectory()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 15))!
        let todayMorning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 8))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 8))!
        let longAgo = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 8))!   // outside the 7-day window

        let history = makeHistory(dir: dir)
        await history.ready()
        let store = try #require(history.store)
        _ = try store.insert(draft("four five", at: now, duration: 30))              // today: 2 words
        _ = try store.insert(draft("one two three", at: todayMorning, duration: 90)) // today: 3 words
        _ = try store.insert(draft("six", at: yesterday))                            // yesterday
        _ = try store.insert(draft("seven", at: longAgo))                            // 8 days back: not in the week, breaks the streak

        let stats = StatsService(history: history, now: { now }, calendar: calendar, fullUserName: { "Artem Semenov" })
        await stats.refresh()

        let expectedPace = HomeStats.pace(words: 5, minutes: 120 / 60)
        let expectedSaved = HomeStats.minutesSaved(words: 5, minutes: 120 / 60)
        #expect(stats.today == HomeStats(words: 5, dictations: 2, paceWPM: expectedPace, minutesSaved: expectedSaved))
        #expect(stats.week.count == StatsService.weekDays)
        #expect(stats.weekTotal == 6)         // today's 5 + yesterday's 1; longAgo falls outside the window
        #expect(stats.streak == 2)            // today, yesterday; the day before has nothing
        #expect(stats.recent.map(\.text) == ["four five", "one two three", "six", "seven"])
        #expect(stats.greeting == "Good afternoon, Artem")           // hour 15 in the injected UTC calendar
        #expect(stats.dateLine.hasSuffix("· 2-day streak"))
    }

    @Test("refresh on an empty store: zeroed stats, no streak, nothing recent")
    func refreshEmptyStore() async throws {
        let dir = TemporaryDirectory()
        let history = makeHistory(dir: dir)
        let stats = StatsService(history: history, now: Date.init, calendar: .current, fullUserName: { "Nobody" })
        await stats.refresh()

        #expect(stats.today == .empty)
        #expect(stats.week.allSatisfy { $0.words == 0 })
        #expect(stats.weekTotal == 0)
        #expect(stats.streak == 0)
        #expect(stats.recent.isEmpty)
    }

    @Test("StatsService subscribes itself to history.onChange: a delete (or reinsert) refreshes without an explicit call")
    func onChangeTriggersRefresh() async throws {
        let dir = TemporaryDirectory()
        let history = makeHistory(dir: dir)
        await history.ready()
        let store = try #require(history.store)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let keep = try store.insert(draft("keep", at: now))
        let removeMe = try store.insert(draft("remove me", at: now))

        let stats = StatsService(history: history, now: { now })
        await stats.refresh()
        #expect(stats.today.dictations == 2)

        await history.delete(id: removeMe.id)
        await waitUntil { stats.today.dictations == 1 }
        #expect(stats.today.dictations == 1)
        #expect(stats.recent.map(\.id) == [keep.id])

        let restored = try #require(await history.reinsert(removeMe))
        await waitUntil { stats.today.dictations == 2 }
        #expect(stats.today.dictations == 2)
        #expect(Set(stats.recent.map(\.id)) == Set([keep.id, restored.id]))
    }

    @Test("a save through HistoryWriter, wired the way AppServices wires onSaved to notifyChanged(), bumps StatsService.today.words without any explicit refresh() call (C1)")
    func historyWriterSaveRefreshesStats() async throws {
        let dir = TemporaryDirectory()
        let history = makeHistory(dir: dir)
        await history.ready()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let stats = StatsService(history: history, now: { now })
        await stats.refresh()
        #expect(stats.today.words == 0)

        let sink = TestHistorySavedSink()
        sink.attach(history)
        let settings = DictationSettingsBox(DictationSettingsSnapshot(excludedBundleIDs: [], keepHistory: true, options: TranscriptionOptions()))
        let writer = HistoryWriter(storeBox: history.storeBox, settings: settings, now: { now },
                                   ready: { await history.ready() }, onSaved: { await sink.notify() })
        let result = DictationResult(text: "one two three four five", rawText: "one two three four five", segments: [],
                                     language: LanguageDetection(code: "en", confidence: 0.9), duration: 3, lowConfidence: false)

        await writer.save(result, appName: "Mail")

        await waitUntil { stats.today.words == 5 }
        #expect(stats.today.words == 5)
        #expect(stats.today.dictations == 1)
    }
}
