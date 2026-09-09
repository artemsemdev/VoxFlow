import Foundation
import SwiftUI
import VoxFlowDictation
import VoxFlowStorage

/// One row of the "Setup" card (design MW-01e, ruling 3): permission/model/hotkey status, plus the
/// action its trailing link performs. A plain value type (not a stored closure) so `HomeViewModel`
/// stays testable by inspecting `action` directly instead of invoking an opaque callback, and so
/// `SetupRow` itself can be `Equatable`.
struct SetupRow: Identifiable, Equatable {
    enum Kind: Equatable { case ok, attention }
    enum Action: Equatable { case none, openMicrophoneSettings, openAccessibilitySettings, openModel, openHotkey }

    var id: String
    var kind: Kind
    var label: String
    var valueText: String
    /// True when `valueText` is a tappable action ("Open Settings" / "Download" / "Change") rather
    /// than a plain status string ("Granted" / the installed model's name).
    var isLink: Bool
    var action: Action
}

/// One of Home's four top stat cards (design MW-01 ruling 1 / MW-01e first-run placeholders).
struct HomeStatCard: Identifiable, Equatable {
    var id: String
    var label: String
    var value: String
    var unit: String?
}

/// One row of the "Recent" card (design ruling 1): coloured initial tile + text + a Home-specific
/// meta line. See `HomeRecentRow.make` for why this isn't `HistoryViewModel.metaLine` verbatim.
struct HomeRecentRow: Identifiable, Equatable {
    var id: Int64
    var initial: String
    var color: Color
    var text: String
    var metaLine: String
}

/// What Home needs to know about the installed speech model — `ModelLoader.readiness()` only
/// reports readiness (ruling 9: the one place that knows which model is loaded), not the model's
/// display name, so `AppServices` bundles both from `ModelStore` into this for the "Speech model"
/// setup row (design MW-01e: "large-v3-turbo" or "Download").
struct HomeModelStatus: Sendable, Equatable {
    var readiness: ModelReadiness
    var displayName: String?
}

/// State and rules of the Home page (design MW-01, MW-01e; rulings 1-3). Views render it; nothing
/// else decides.
@Observable @MainActor
final class HomeViewModel {
    private let stats: StatsService
    private let settings: DictationSettings
    private let permissions: any PermissionChecking
    private let modelStatus: @Sendable () async -> HomeModelStatus
    private let navigation: Navigation
    private let ephemeralScope: EphemeralScope
    private let now: () -> Date
    private let fullUserName: () -> String

    private(set) var setupRows: [SetupRow] = []

    init(stats: StatsService, settings: DictationSettings, permissions: any PermissionChecking,
         modelStatus: @escaping @Sendable () async -> HomeModelStatus, navigation: Navigation,
         ephemeralScope: EphemeralScope, now: @escaping () -> Date = Date.init,
         fullUserName: @escaping () -> String = NSFullUserName) {
        self.stats = stats
        self.settings = settings
        self.permissions = permissions
        self.modelStatus = modelStatus
        self.navigation = navigation
        self.ephemeralScope = ephemeralScope
        self.now = now
        self.fullUserName = fullUserName
    }

    /// Re-derives everything: the store's numbers (`StatsService.refresh()`) and the Setup rows.
    /// Permissions are read synchronously (`PermissionChecking` isn't async); the model's
    /// readiness/name needs an await, so this whole pass is `async`. Called from `HomePage`'s
    /// `.task` — same pattern as `HistoryViewModel.refresh()` on every navigation back to Home.
    func refresh() async {
        await stats.refresh()
        let model = await modelStatus()
        setupRows = Self.buildSetupRows(microphone: permissions.microphone(),
                                        accessibilityTrusted: permissions.accessibilityTrusted(prompt: false),
                                        model: model, hotkeyMode: settings.hotkeyMode)
    }

    // MARK: Header (design ruling 2 — delegated to `StatsService`, the one place that owns "now"
    // for the greeting/date line, so this view model doesn't duplicate that logic)

    var greeting: String { stats.greeting }
    var dateLine: String { stats.dateLine }
    var modeChip: String { settings.hotkeyMode == .pushToTalk ? "Push-to-talk · fn" : "Hands-free · fn" }

    /// The header's big line: MW-01e's "Welcome, {Name}" on first run, `greeting` ("Good morning,
    /// {Name}") on every later visit.
    var headerTitle: String {
        isFirstRun ? "Welcome, \(Greeting.firstName(from: fullUserName()))" : greeting
    }

    /// The header's small line: MW-01e's fixed copy on first run, `dateLine` otherwise.
    var headerSubtitle: String {
        isFirstRun ? "Everything is set up. Your stats appear after the first dictation." : dateLine
    }

    // MARK: First run (design MW-01e, ruling 3)

    /// No dictation has ever been saved. `StatsService.recent` is the store's most-recent-first
    /// list with no date filter (`DictationStore.fetch(limit:)` orders by `created_at DESC` with no
    /// `WHERE`), so an empty list here means exactly "zero dictations ever" — not just "none today".
    ///
    /// Gated on `stats.isHistoryAvailable`: a disabled store (lost Keychain key, failed open) also
    /// leaves `recent` empty, but that's "can't read history right now", not "welcome, first-timer"
    /// — review minor 1. A disabled store falls through to the normal MW-01 layout instead, where
    /// every number reads its ordinary empty-state value (0 / "—" pace) rather than the first-run
    /// placeholders.
    var isFirstRun: Bool { stats.recent.isEmpty && stats.isHistoryAvailable }

    /// Ruling 3 / 3e: the Setup card shows on first run, and again on a returning MW-01 whenever a
    /// permission (not the model) is missing — a model download in progress doesn't re-litigate
    /// setup for someone who has already dictated at least once.
    var showsSetupCard: Bool {
        isFirstRun || setupRows.contains { $0.id == "permissions" && $0.kind == .attention }
    }

    // MARK: Stat cards (design ruling 1)

    var statCards: [HomeStatCard] {
        guard !isFirstRun else {
            return [
                HomeStatCard(id: "words", label: "Words today", value: "—", unit: nil),
                HomeStatCard(id: "saved", label: "Time saved", value: "—", unit: nil),
                HomeStatCard(id: "pace", label: "Speaking pace", value: "—", unit: nil),
                HomeStatCard(id: "dictations", label: "Dictations", value: "0", unit: nil),
            ]
        }
        let today = stats.today
        return [
            HomeStatCard(id: "words", label: "Words today", value: Self.grouped(today.words), unit: nil),
            HomeStatCard(id: "saved", label: "Time saved", value: Self.grouped(today.minutesSaved), unit: "min"),
            HomeStatCard(id: "pace", label: "Speaking pace",
                        value: today.paceWPM.map(Self.grouped) ?? "—", unit: today.paceWPM != nil ? "wpm" : nil),
            HomeStatCard(id: "dictations", label: "Dictations", value: Self.grouped(today.dictations), unit: nil),
        ]
    }

    // MARK: Recent + This week (design ruling 1)

    var recentRows: [HomeRecentRow] { stats.recent.map { HomeRecentRow.make(from: $0, now: now()) } }
    var week: [DayWords] { stats.week }
    var weekTotalText: String { "\(Self.grouped(stats.weekTotal)) words" }
    /// What `WeekChart` compares each bucket's date against to decide which bar is "today" — this
    /// view model's own `now()`, not the view's system clock, so a test-injected `now` (and, in
    /// production, the moment `refresh()` last ran) is what actually drives the accent, not array
    /// position (review minor 3).
    var referenceDate: Date { now() }

    func seeAll() { navigation.page = .history }

    // MARK: Scratchpad (design MW-01e "Try it here") — same `EphemeralScope` History's own
    // scratchpad sheet uses, entered/left as the "Try it here" card appears/disappears.

    func enterScratchpad() { ephemeralScope.enter() }
    func leaveScratchpad() { ephemeralScope.leave() }

    // MARK: Setup row actions

    func perform(_ action: SetupRow.Action) {
        switch action {
        case .none: break
        case .openMicrophoneSettings: permissions.openMicrophoneSettings()
        case .openAccessibilitySettings: permissions.openAccessibilitySettings()
        case .openModel:
            navigation.settingsTab = .models
            navigation.page = .settings
        case .openHotkey:
            navigation.settingsTab = .hotkeys
            navigation.page = .settings
        }
    }

    // MARK: Pure helpers

    /// "1,240" — a fixed `en_US_POSIX` grouping regardless of the system locale, same reasoning as
    /// `ResultViewModel.wordCountFormatter`: the design specifies this exact formatting.
    nonisolated static func grouped(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private nonisolated static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        return formatter
    }()

    nonisolated static func buildSetupRows(microphone: PermissionState, accessibilityTrusted: Bool, model: HomeModelStatus,
                                           hotkeyMode: HotkeyMode) -> [SetupRow] {
        let micGranted = microphone == .granted
        let permissionsGranted = micGranted && accessibilityTrusted
        let permissionsRow = SetupRow(
            id: "permissions", kind: permissionsGranted ? .ok : .attention,
            label: "Microphone & Accessibility",
            valueText: permissionsGranted ? "Granted" : "Open Settings",
            isLink: !permissionsGranted,
            action: permissionsGranted ? .none : (micGranted ? .openAccessibilitySettings : .openMicrophoneSettings))

        let modelInstalled: Bool
        switch model.readiness {
        case .loaded, .installedNotLoaded: modelInstalled = true
        case .notInstalled: modelInstalled = false
        }
        let modelRow = SetupRow(
            id: "model", kind: modelInstalled ? .ok : .attention,
            label: "Speech model",
            valueText: modelInstalled ? (model.displayName ?? "Installed") : "Download",
            isLink: !modelInstalled,
            action: modelInstalled ? .none : .openModel)

        let hotkeyRow = SetupRow(
            id: "hotkey", kind: .ok,
            label: "Hotkey · " + (hotkeyMode == .pushToTalk ? "hold fn" : "double-tap fn"),
            valueText: "Change", isLink: true, action: .openHotkey)

        return [permissionsRow, modelRow, hotkeyRow]
    }
}

extension HomeRecentRow {
    /// Reuses `HistoryViewModel`'s tile helpers (`initial`/`color`/`displayText`) so the Recent
    /// card's tiles match History's exactly — only the meta line's shape differs: design MW-01/12
    /// shows "App · N min ago · N words · Style" (relative time, no duration, no absolute clock
    /// time), not History's "App · h:mm a · m:ss · N words · Style · LANG".
    ///
    /// `@MainActor`, not `nonisolated`: `HistoryViewModel`'s static helpers are themselves
    /// main-actor-isolated (they live on an `@MainActor` class), so a caller reusing them must be
    /// too — every real call site (`HomeViewModel.recentRows`) already is.
    @MainActor
    static func make(from record: DictationRecord, now: Date) -> HomeRecentRow {
        let appLabel: String
        if let appName = record.appName, !appName.isEmpty { appLabel = appName } else { appLabel = "Unknown app" }
        var parts = [appLabel]
        parts.append(timeAgo(from: record.createdAt, now: now))
        parts.append("\(record.words) words")
        if let style = record.style, !style.isEmpty { parts.append(HistoryViewModel.styleLabel(style)) }
        return HomeRecentRow(id: record.id, initial: HistoryViewModel.initial(for: record.appName),
                             color: HistoryViewModel.color(for: record.appName),
                             text: HistoryViewModel.displayText(for: record), metaLine: parts.joined(separator: " · "))
    }

    /// "2 min ago" / "1 h ago" / "3 d ago" — floored, never negative (a record whose clock is a
    /// hair ahead of `now` still reads "just now" rather than something nonsensical like "-1 min
    /// ago"). Design examples (canvas page 12) are all whole units: "2 min ago", "14 min ago",
    /// "1 h ago", "3 h ago".
    static func timeAgo(from date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        return "\(hours / 24) d ago"
    }
}
