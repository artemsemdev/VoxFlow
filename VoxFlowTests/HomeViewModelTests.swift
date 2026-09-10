import CryptoKit
import Foundation
import Testing
import VoxFlowCore
import VoxFlowDictation
import VoxFlowStorage
import VoxFlowTestSupport
@testable import VoxFlow

private struct FakeHistoryKeyProvider: HistoryKeyProviding {
    func historyKey() throws -> HistoryKey { HistoryKey(key: SymmetricKey(size: .bits256), isNewlyCreated: false) }
}

/// Claims `isNewlyCreated: true` on every call — opening an *already-encrypted* database with this
/// is exactly what `DictationStore` treats as "the original key is gone" (`StorageError.keyLost`),
/// mirroring `HistoryViewModelTests.emptyStateUnavailableWhenHistoryDisabled`'s harness.
private struct FakeFreshKeyProvider: HistoryKeyProviding {
    func historyKey() throws -> HistoryKey { HistoryKey(key: SymmetricKey(size: .bits256), isNewlyCreated: true) }
}

@Suite("HomeRecentRow")
@MainActor
struct HomeRecentRowTests {
    @Test("timeAgo: floors to whole minutes/hours/days; never negative")
    func timeAgo() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(HomeRecentRow.timeAgo(from: now, now: now) == "just now")
        #expect(HomeRecentRow.timeAgo(from: now.addingTimeInterval(2), now: now) == "just now")          // clock skew: never negative
        #expect(HomeRecentRow.timeAgo(from: now.addingTimeInterval(-59), now: now) == "just now")
        #expect(HomeRecentRow.timeAgo(from: now.addingTimeInterval(-2 * 60), now: now) == "2 min ago")
        #expect(HomeRecentRow.timeAgo(from: now.addingTimeInterval(-14 * 60), now: now) == "14 min ago")
        #expect(HomeRecentRow.timeAgo(from: now.addingTimeInterval(-59 * 60), now: now) == "59 min ago")
        #expect(HomeRecentRow.timeAgo(from: now.addingTimeInterval(-60 * 60), now: now) == "1 h ago")
        #expect(HomeRecentRow.timeAgo(from: now.addingTimeInterval(-3 * 3600), now: now) == "3 h ago")
        #expect(HomeRecentRow.timeAgo(from: now.addingTimeInterval(-23 * 3600), now: now) == "23 h ago")
        #expect(HomeRecentRow.timeAgo(from: now.addingTimeInterval(-24 * 3600), now: now) == "1 d ago")
        #expect(HomeRecentRow.timeAgo(from: now.addingTimeInterval(-3 * 24 * 3600), now: now) == "3 d ago")
    }

    @Test("make: reuses HistoryViewModel's tile helpers; Home-specific relative meta line")
    func make() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let record = DictationRecord(id: 1, text: "hello there", rawText: "um hello there", appName: "Mail",
                                     style: "formal", language: "en", duration: 12, words: 17,
                                     createdAt: now.addingTimeInterval(-2 * 60))
        let row = HomeRecentRow.make(from: record, now: now)
        #expect(row.id == 1)
        #expect(row.initial == "M")
        #expect(row.color == HistoryViewModel.color(for: "Mail"))
        #expect(row.text == "hello there")
        #expect(row.metaLine == "Mail · 2 min ago · 17 words · Formal")
    }

    @Test("make: no style, no app name")
    func makeMinimal() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let record = DictationRecord(id: 2, text: "hi", rawText: "hi", appName: nil, style: nil, language: nil,
                                     duration: 1, words: 1, createdAt: now)
        let row = HomeRecentRow.make(from: record, now: now)
        #expect(row.initial == "?")
        #expect(row.metaLine == "Unknown app · just now · 1 words")
    }
}

@Suite("HomeViewModel.grouped")
struct HomeViewModelGroupedTests {
    @Test("grouped: en_US_POSIX grouping regardless of caller's locale")
    func grouped() {
        #expect(HomeViewModel.grouped(0) == "0")
        #expect(HomeViewModel.grouped(146) == "146")
        #expect(HomeViewModel.grouped(1_240) == "1,240")
        #expect(HomeViewModel.grouped(6_910) == "6,910")
    }
}

@Suite("HomeViewModel.buildSetupRows")
struct HomeViewModelSetupRowsTests {
    @Test("permissions: both granted -> ok/Granted/no action")
    func permissionsGranted() {
        let rows = HomeViewModel.buildSetupRows(microphone: .granted, accessibilityTrusted: true,
                                                model: HomeModelStatus(readiness: .loaded, displayName: "large-v3-turbo"),
                                                hotkeyMode: .pushToTalk)
        let row = rows[0]
        #expect(row.id == "permissions")
        #expect(row.kind == .ok)
        #expect(row.valueText == "Granted")
        #expect(row.isLink == false)
        #expect(row.action == .none)
    }

    @Test("permissions: microphone denied -> attention/Open Settings/openMicrophoneSettings")
    func microphoneDenied() {
        let rows = HomeViewModel.buildSetupRows(microphone: .denied, accessibilityTrusted: true,
                                                model: HomeModelStatus(readiness: .loaded, displayName: "large-v3-turbo"),
                                                hotkeyMode: .pushToTalk)
        let row = rows[0]
        #expect(row.kind == .attention)
        #expect(row.valueText == "Open Settings")
        #expect(row.isLink)
        #expect(row.action == .openMicrophoneSettings)
    }

    @Test("permissions: microphone granted, accessibility not trusted -> openAccessibilitySettings")
    func accessibilityNotTrusted() {
        let rows = HomeViewModel.buildSetupRows(microphone: .granted, accessibilityTrusted: false,
                                                model: HomeModelStatus(readiness: .loaded, displayName: "large-v3-turbo"),
                                                hotkeyMode: .pushToTalk)
        #expect(rows[0].kind == .attention)
        #expect(rows[0].action == .openAccessibilitySettings)
    }

    @Test("model: installed -> ok, its display name, no action")
    func modelInstalled() {
        let rows = HomeViewModel.buildSetupRows(microphone: .granted, accessibilityTrusted: true,
                                                model: HomeModelStatus(readiness: .installedNotLoaded, displayName: "large-v3-turbo"),
                                                hotkeyMode: .pushToTalk)
        let row = rows[1]
        #expect(row.id == "model")
        #expect(row.kind == .ok)
        #expect(row.valueText == "large-v3-turbo")
        #expect(row.isLink == false)
    }

    @Test("model: not installed -> attention/Download/openModel")
    func modelNotInstalled() {
        let rows = HomeViewModel.buildSetupRows(microphone: .granted, accessibilityTrusted: true,
                                                model: HomeModelStatus(readiness: .notInstalled(sizeBytes: 100), displayName: nil),
                                                hotkeyMode: .pushToTalk)
        let row = rows[1]
        #expect(row.kind == .attention)
        #expect(row.valueText == "Download")
        #expect(row.isLink)
        #expect(row.action == .openModel)
    }

    @Test("hotkey: push-to-talk -> 'hold fn'; hands-free -> 'double-tap fn'; always ok, always Change")
    func hotkeyLabel() {
        let model = HomeModelStatus(readiness: .loaded, displayName: "large-v3-turbo")
        let pushToTalk = HomeViewModel.buildSetupRows(microphone: .granted, accessibilityTrusted: true, model: model, hotkeyMode: .pushToTalk)[2]
        #expect(pushToTalk.label == "Hotkey · hold fn")
        #expect(pushToTalk.kind == .ok)
        #expect(pushToTalk.valueText == "Change")
        #expect(pushToTalk.action == .openHotkey)

        let handsFree = HomeViewModel.buildSetupRows(microphone: .granted, accessibilityTrusted: true, model: model, hotkeyMode: .handsFree)[2]
        #expect(handsFree.label == "Hotkey · double-tap fn")
    }
}

@Suite("HomeViewModel", .timeLimit(.minutes(1)))
@MainActor
struct HomeViewModelTests {
    @MainActor
    struct Harness {
        let dir = TemporaryDirectory()
        let navigation = Navigation()
        let dictationSettings: DictationSettings
        let history: HistoryService
        let stats: StatsService
        let permissions: FakePermissions
        let ephemeralScope = EphemeralScope()
        let vm: HomeViewModel

        init(now: Date = Date(timeIntervalSince1970: 2_000_000_000),
             microphone: PermissionState = .granted, accessibility: Bool = true,
             modelStatus: HomeModelStatus = HomeModelStatus(readiness: .loaded, displayName: "large-v3-turbo"),
             fullUserName: @escaping () -> String = { "Artem Semenov" }) {
            dictationSettings = DictationSettings(store: InMemoryKeyValueStore())
            dictationSettings.retentionDays = 0
            dictationSettings.encryptHistory = false
            history = HistoryService(url: dir.file("voxflow.sqlite"), settings: dictationSettings,
                                     keyProvider: { FakeHistoryKeyProvider() }, clock: FakeClock())
            stats = StatsService(history: history, now: { now })
            permissions = FakePermissions(microphone: microphone, requestResult: microphone, accessibility: accessibility)
            vm = HomeViewModel(stats: stats, settings: dictationSettings, permissions: permissions,
                               modelStatus: { modelStatus }, navigation: navigation,
                               ephemeralScope: ephemeralScope, now: { now }, fullUserName: fullUserName)
        }

        func draft(_ text: String, appName: String = "Mail", style: String? = "formal", at date: Date) -> DictationDraft {
            DictationDraft(text: text, rawText: text, appName: appName, style: style, language: "en", duration: 6, createdAt: date)
        }

        @discardableResult
        func seedOneDictation(at date: Date) async throws -> DictationRecord {
            _ = await history.count()   // force the open to finish
            return try history.store!.insert(draft("hello", at: date))
        }
    }

    @Test("greeting/dateLine delegate to StatsService")
    func greetingDelegates() async {
        let h = Harness()
        #expect(h.vm.greeting == h.stats.greeting)
        #expect(h.vm.dateLine == h.stats.dateLine)
    }

    @Test("headerTitle/headerSubtitle: first-run MW-01e copy on first run, greeting/dateLine otherwise")
    func headerFollowsFirstRun() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let h = Harness(now: now, fullUserName: { "Anh Nguyen" })
        await h.vm.refresh()
        #expect(h.vm.headerTitle == "Welcome, Anh")
        #expect(h.vm.headerSubtitle == "Everything is set up. Your stats appear after the first dictation.")

        try await h.seedOneDictation(at: now)
        await h.vm.refresh()
        #expect(h.vm.headerTitle == h.stats.greeting)
        #expect(h.vm.headerSubtitle == h.stats.dateLine)
    }

    @Test("modeChip follows hotkeyMode")
    func modeChip() {
        let h = Harness()
        #expect(h.vm.modeChip == "Push-to-talk · fn")
        h.dictationSettings.hotkeyMode = .handsFree
        #expect(h.vm.modeChip == "Hands-free · fn")
    }

    @Test("isFirstRun: true with no dictations, false once one exists")
    func firstRunSwitches() async throws {
        let h = Harness()
        await h.vm.refresh()
        #expect(h.vm.isFirstRun)
        #expect(h.vm.statCards.map(\.value) == ["—", "—", "—", "0"])

        try await h.seedOneDictation(at: Date(timeIntervalSince1970: 2_000_000_000))
        await h.vm.refresh()
        #expect(!h.vm.isFirstRun)
    }

    @Test("isFirstRun: false when the history store is unavailable — normal page with zeroed stats, not the first-run welcome")
    func firstRunFalseWhenHistoryUnavailable() async throws {
        let dir = TemporaryDirectory()
        let url = dir.file("voxflow.sqlite")
        // An already-encrypted database on disk (mirrors `HistoryViewModelTests`' harness): opening
        // it below with a "fresh" key provider makes `DictationStore` throw `.keyLost`, landing
        // `HistoryService.status` in `.disabled` — `recent` ends up empty exactly like a genuinely
        // first-time user, so this is the case review minor 1 is about.
        _ = try DictationStore(databaseURL: url, keyProvider: FakeHistoryKeyProvider())
            .insert(DictationDraft(text: "secret", rawText: "secret", appName: "Mail", style: nil,
                                   language: "en", duration: 1, createdAt: Date()))

        let settings = DictationSettings(store: InMemoryKeyValueStore())
        settings.retentionDays = 0
        let brokenHistory = HistoryService(url: url, settings: settings, keyProvider: { FakeFreshKeyProvider() }, clock: FakeClock())
        let stats = StatsService(history: brokenHistory)
        let navigation = Navigation()
        let permissions = FakePermissions(microphone: .granted, requestResult: .granted, accessibility: true)
        let vm = HomeViewModel(stats: stats, settings: settings, permissions: permissions,
                               modelStatus: { HomeModelStatus(readiness: .loaded, displayName: "large-v3-turbo") },
                               navigation: navigation, ephemeralScope: EphemeralScope())
        await vm.refresh()

        #expect(!stats.isHistoryAvailable)
        #expect(!vm.isFirstRun)
        // Normal-page formatting of an all-zero `HomeStats`, not the first-run "—/—/—/0" placeholders.
        #expect(vm.statCards.map(\.value) == ["0", "0", "—", "0"])
        withExtendedLifetime(dir) {}   // the temp dir must outlive the broken service's open attempt
    }

    @Test("showsSetupCard: true on first run even with every permission granted")
    func showsSetupCardFirstRun() async {
        let h = Harness()
        await h.vm.refresh()
        #expect(h.vm.showsSetupCard)
    }

    @Test("showsSetupCard: false once dictated with every permission granted")
    func hidesSetupCardOnceDictatedAndGranted() async throws {
        let h = Harness()
        try await h.seedOneDictation(at: Date(timeIntervalSince1970: 2_000_000_000))
        await h.vm.refresh()
        #expect(!h.vm.showsSetupCard)
    }

    @Test("showsSetupCard: ruling 3e — returns once dictated whenever a permission is missing")
    func returnsWhenPermissionMissing() async throws {
        let h = Harness(microphone: .denied)
        try await h.seedOneDictation(at: Date(timeIntervalSince1970: 2_000_000_000))
        await h.vm.refresh()
        #expect(h.vm.showsSetupCard)
    }

    @Test("showsSetupCard: a missing model alone does not bring the card back once dictated (ruling 3e is permissions-only)")
    func modelMissingAloneDoesNotReturnCard() async throws {
        let h = Harness(modelStatus: HomeModelStatus(readiness: .notInstalled(sizeBytes: 1), displayName: nil))
        try await h.seedOneDictation(at: Date(timeIntervalSince1970: 2_000_000_000))
        await h.vm.refresh()
        #expect(!h.vm.showsSetupCard)
    }

    @Test("statCards: formatted from today's numbers once dictated")
    func statCardsNormal() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let h = Harness(now: now)
        try await h.seedOneDictation(at: now)
        await h.vm.refresh()
        let cards = h.vm.statCards
        #expect(cards.map(\.label) == ["Words today", "Time saved", "Speaking pace", "Dictations"])
        #expect(cards[0].value == "1")     // "hello" = 1 word
        #expect(cards[3].value == "1")
        #expect(cards[1].unit == "min")
        #expect(cards[2].unit == "wpm")
    }

    @Test("statCards: pace shows '—' with no unit when there was no dictation today")
    func statCardsNoPaceToday() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let yesterday = now.addingTimeInterval(-24 * 3600)
        let h = Harness(now: now)
        try await h.seedOneDictation(at: yesterday)
        await h.vm.refresh()
        let pace = h.vm.statCards[2]
        #expect(pace.value == "—")
        #expect(pace.unit == nil)
    }

    @Test("recentRows: reflects StatsService.recent, most recent first")
    func recentRows() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let h = Harness(now: now)
        try await h.seedOneDictation(at: now.addingTimeInterval(-60))
        try await h.seedOneDictation(at: now)
        await h.vm.refresh()
        #expect(h.vm.recentRows.count == 2)
        #expect(h.vm.recentRows[0].metaLine.contains("just now"))
        #expect(h.vm.recentRows[1].metaLine.contains("1 min ago"))
    }

    @Test("weekTotalText: grouped total + ' words'")
    func weekTotalText() async {
        let h = Harness()
        await h.vm.refresh()
        #expect(h.vm.weekTotalText == "0 words")
    }

    @Test("seeAll navigates to History")
    func seeAll() {
        let h = Harness()
        h.navigation.page = .home
        h.vm.seeAll()
        #expect(h.navigation.page == .history)
    }

    @Test("perform(.openMicrophoneSettings) opens the microphone pane")
    func performOpenMicrophone() {
        let h = Harness()
        h.vm.perform(.openMicrophoneSettings)
        #expect(h.permissions.openedMicrophoneSettings == 1)
    }

    @Test("perform(.openAccessibilitySettings) opens the accessibility pane")
    func performOpenAccessibility() {
        let h = Harness()
        h.vm.perform(.openAccessibilitySettings)
        #expect(h.permissions.openedAccessibilitySettings == 1)
    }

    @Test("perform(.openModel) navigates to Settings > Models")
    func performOpenModel() {
        let h = Harness()
        h.vm.perform(.openModel)
        #expect(h.navigation.page == .settings)
        #expect(h.navigation.settingsTab == .models)
    }

    @Test("perform(.openHotkey) navigates to Settings > Hotkeys")
    func performOpenHotkey() {
        let h = Harness()
        h.vm.perform(.openHotkey)
        #expect(h.navigation.page == .settings)
        #expect(h.navigation.settingsTab == .hotkeys)
    }

    @Test("perform(.none) does nothing observable")
    func performNone() {
        let h = Harness()
        h.vm.perform(.none)
        #expect(h.permissions.openedMicrophoneSettings == 0)
        #expect(h.permissions.openedAccessibilitySettings == 0)
    }

    @Test("scratchpad enter/leave balances EphemeralScope.isActive")
    func scratchpad() {
        let h = Harness()
        #expect(!h.ephemeralScope.isActive)
        h.vm.enterScratchpad()
        #expect(h.ephemeralScope.isActive)
        h.vm.leaveScratchpad()
        #expect(!h.ephemeralScope.isActive)
    }

    @Test("referenceDate is the injected now(), for WeekChart's calendar-driven 'today' (review minor 3)")
    func referenceDate() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let h = Harness(now: now)
        #expect(h.vm.referenceDate == now)
    }
}

@Suite("WeekChart")
@MainActor
struct WeekChartTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test("isToday: same calendar day as referenceDate, regardless of time of day")
    func isTodaySameDay() {
        let referenceDate = date(2026, 9, 9, hour: 15)
        #expect(WeekChart.isToday(date(2026, 9, 9, hour: 0), referenceDate: referenceDate, calendar: utc))
        #expect(WeekChart.isToday(date(2026, 9, 9, hour: 23), referenceDate: referenceDate, calendar: utc))
        #expect(!WeekChart.isToday(date(2026, 9, 8, hour: 23), referenceDate: referenceDate, calendar: utc))
        #expect(!WeekChart.isToday(date(2026, 9, 10, hour: 0), referenceDate: referenceDate, calendar: utc))
    }

    @Test("isToday: driven by the date, not array position — a referenceDate that isn't the last bucket still lights up the right one")
    func isTodayIsNotPositional() {
        // Oldest-first week ending three days *before* referenceDate (e.g. a stale render, or a
        // week array built for a different purpose than `StatsService.week`) — the positional rule
        // (`index == days.count - 1`) this replaces would have wrongly lit the last bucket.
        let referenceDate = date(2026, 9, 9)
        let days = (0..<7).map { offset in date(2026, 9, 3 + offset) }   // Sep 3...Sep 9
        let flags = days.map { WeekChart.isToday($0, referenceDate: referenceDate, calendar: utc) }
        #expect(flags == [false, false, false, false, false, false, true])   // Sep 9 is index 6 here too, but *because* it's the date match

        let daysNotEndingToday = (0..<7).map { offset in date(2026, 9, 1 + offset) }   // Sep 1...Sep 7 — no Sep 9 at all
        #expect(daysNotEndingToday.allSatisfy { !WeekChart.isToday($0, referenceDate: referenceDate, calendar: utc) })
    }

    @Test("barHeight: proportional to the week's max day; a zero-word day still draws barMinHeight, never zero")
    func barHeight() {
        let days = [DayWords(date: date(2026, 9, 1), words: 0), DayWords(date: date(2026, 9, 2), words: 50),
                    DayWords(date: date(2026, 9, 3), words: 100)]
        #expect(WeekChart.barHeight(for: days[0], in: days) == WeekChart.barMinHeight)
        #expect(WeekChart.barHeight(for: days[2], in: days) == WeekChart.barMaxHeight)   // the max day fills the full height
        #expect(WeekChart.barHeight(for: days[1], in: days) == WeekChart.barMaxHeight / 2)

        // An all-zero week degrades to a flat row of minimum-height slivers rather than dividing by 0.
        let allZero = [DayWords(date: date(2026, 9, 1), words: 0), DayWords(date: date(2026, 9, 2), words: 0)]
        #expect(allZero.allSatisfy { WeekChart.barHeight(for: $0, in: allZero) == WeekChart.barMinHeight })
    }

    @Test("letter: very-short weekday symbol, matching the canvas's T W T F S S M for a week ending Monday")
    func letter() {
        let locale = Locale(identifier: "en_US")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = locale
        // Sept 1, 2026 is a Tuesday; a 7-day window ending Monday Sept 7 is Tue…Mon.
        let letters = (1...7).map { day in WeekChart.letter(for: date(2026, 9, day), calendar: calendar) }
        #expect(letters == ["T", "W", "T", "F", "S", "S", "M"])
    }
}
