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
}
