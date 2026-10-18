import Foundation
import VoxFlowStorage

/// Home page "today" numbers (design MW-01, ruling 1: Words today / Time saved / Speaking pace /
/// Dictations).
struct HomeStats: Equatable {
    var words: Int
    var dictations: Int
    /// nil ("—") when there was no dictation today (`minutes == 0`).
    var paceWPM: Int?
    var minutesSaved: Int

    static let empty = HomeStats(words: 0, dictations: 0, paceWPM: nil, minutesSaved: 0)

    /// Ruling 1: words typed at 40 wpm minus the minutes actually spent dictating, floored at 0 —
    /// dictation that's slower than typing (a short, halting session) never shows negative "time saved".
    static func minutesSaved(words: Int, minutes: Double) -> Int {
        max(0, Int((Double(words) / 40 - minutes).rounded(.down)))
    }

    /// Ruling 1: words ÷ total dictation minutes; nil ("—") when there was no dictation at all today.
    static func pace(words: Int, minutes: Double) -> Int? {
        guard minutes > 0 else { return nil }
        return Int((Double(words) / minutes).rounded())
    }
}

/// Home page header copy (design ruling 2).
enum Greeting {
    static func text(hour: Int) -> String {
        switch hour {
        case ..<12: "Good morning"
        case ..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    /// "Monday, September 7" (long weekday, month day, `locale`) + " · N-day streak" once `streak`
    /// reaches 2 — ruling 1: hidden below that (0 or 1 doesn't read as a "streak").
    static func dateLine(date: Date, streak: Int, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "EEEE, MMMM d"
        let base = formatter.string(from: date)
        return streak >= 2 ? base + " · \(streak)-day streak" : base
    }

    /// First token of `NSFullUserName()` — the whole string when it has no separating space.
    static func firstName(from fullName: String) -> String {
        fullName.split(separator: " ").first.map(String.init) ?? fullName
    }
}

/// Home page + menu bar numbers (design MW-01, ruling 1), computed from `DictationStore`'s aggregate
/// queries. Subscribes itself to `history.onChange` so a dictation, a History delete/undo, or a
/// retention purge all keep these numbers live without any caller having to remember to ask again —
/// `AppServices` builds this once, and `AppDelegate` (non-test launch path, review C1) triggers the
/// very first `refresh()` right after `historyService.ready()` resolves, so Home and the menu bar
/// show real numbers without anyone having to navigate to Home first.
@Observable @MainActor
final class StatsService {
    static let weekDays = 7
    static let recentLimit = 4

    private(set) var today: HomeStats = .empty
    /// Last `weekDays` local calendar days ending today, oldest first, zero-filled (design "This week").
    private(set) var week: [DayWords] = []
    private(set) var weekTotal = 0
    /// Consecutive days ending today with ≥ 1 dictation; 0 hides the "N-day streak" chip (ruling 1).
    private(set) var streak = 0
    /// Last `recentLimit` dictations for the Home page's "Recent" list (design ruling 1).
    private(set) var recent: [DictationRecord] = []

    /// False while the history store itself is unavailable this session (`HistoryService.status ==
    /// .disabled`, e.g. a lost Keychain key) — `refresh()` zeroes `recent`/`today`/`week` exactly the
    /// same way it does for a genuinely empty store, so `HomeViewModel.isFirstRun` needs this to tell
    /// "no dictations ever" apart from "can't read the store right now" (review minor 1).
    var isHistoryAvailable: Bool {
        if case .disabled = history.status { return false }
        return true
    }

    private let history: HistoryService
    private let now: () -> Date
    private let calendar: Calendar
    private let fullUserName: () -> String

    init(history: HistoryService, now: @escaping () -> Date = Date.init, calendar: Calendar = .current,
         fullUserName: @escaping () -> String = NSFullUserName) {
        self.history = history
        self.now = now
        self.calendar = calendar
        self.fullUserName = fullUserName
        // `HistoryService.onChange` is a single-subscriber hook (see its doc comment) — this is the
        // one intended subscriber. Deferred to the next main-actor turn via `Task` rather than called
        // straight from the closure body: `onChange` isn't itself `@MainActor`-typed, and `refresh()`
        // is `async` regardless.
        history.onChange = { [weak self] in Task { @MainActor in await self?.refresh() } }
    }

    /// Recomputes every published number. The aggregate queries are blocking SQLite I/O (see
    /// `DictationStore`'s doc comment), so they run together on one detached task; `history.ready()`
    /// is awaited first so a `refresh()` issued right after launch (or a settings-driven reopen)
    /// doesn't race the store's first open and read a stale `nil`.
    func refresh() async {
        await history.ready()
        guard let store = history.store else {
            today = .empty
            week = []
            weekTotal = 0
            streak = 0
            recent = []
            return
        }
        let calendar = self.calendar
        let referenceDate = now()
        let todayStart = calendar.startOfDay(for: referenceDate)
        let weekDays = Self.weekDays
        let recentLimit = Self.recentLimit

        let (stats, week, streakValue, recentRecords) = await Task.detached(priority: .userInitiated) {
            () -> (DictationStats, [DayWords], Int, [DictationRecord]) in
            let stats = (try? store.stats(since: todayStart)) ?? DictationStats(count: 0, words: 0, duration: 0)
            let week = (try? store.wordsPerDay(days: weekDays, endingAt: referenceDate, calendar: calendar)) ?? []
            let streak = (try? store.streak(endingAt: referenceDate, calendar: calendar)) ?? 0
            let recent = (try? store.fetch(limit: recentLimit)) ?? []
            return (stats, week, streak, recent)
        }.value

        let minutes = stats.duration / 60
        today = HomeStats(words: stats.words, dictations: stats.count,
                          paceWPM: HomeStats.pace(words: stats.words, minutes: minutes),
                          minutesSaved: HomeStats.minutesSaved(words: stats.words, minutes: minutes))
        self.week = week
        weekTotal = week.reduce(0) { $0 + $1.words }
        streak = streakValue
        recent = recentRecords
    }

    /// "Good morning, Artem" (design ruling 2) — recomputed from `now`/`fullUserName` on every read
    /// rather than cached, so it's never stale across a midnight boundary.
    var greeting: String {
        "\(Greeting.text(hour: calendar.component(.hour, from: now()))), \(Greeting.firstName(from: fullUserName()))"
    }

    /// "Monday, September 7 · 12-day streak" (design ruling 2), built from this service's own
    /// published `streak` so it's always in step with `today`/`week`.
    var dateLine: String { Greeting.dateLine(date: now(), streak: streak, locale: calendar.locale ?? Locale.current) }
}
