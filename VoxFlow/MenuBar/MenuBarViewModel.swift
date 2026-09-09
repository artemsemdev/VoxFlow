import AppKit
import Foundation
import SwiftUI
import VoxFlowDictation
import VoxFlowModels

/// Drives the menu bar dropdown (design MB-01 "Ready", MB-02 "Paused"/"Downloading") — status,
/// hands-free toggle, today's stats, item actions, the language submenu and the footer. Views hold
/// no rules: every string/number decision the dropdown shows lives here, tested directly.
/// `MenuBarServices` builds the one live instance over the shared `AppServices`/`SettingsServices`
/// composition roots.
@Observable @MainActor
final class MenuBarViewModel {
    /// "Pause dictation for 1 hour" (design MB-01 item copy).
    static let pauseDuration: TimeInterval = 3600

    /// Same seven choices as Settings › General's language picker (ruling 6: "the same picker as
    /// General") — `nil` code means auto-detect.
    static let languages: [(code: String?, label: String)] = [
        (nil, "Auto-detect"), ("en", "English"), ("es", "Español"), ("fr", "Français"),
        ("de", "Deutsch"), ("ja", "日本語"), ("pt", "Português"),
    ]

    private let dictation: DictationCoordinator
    private let settings: DictationSettings
    private let stats: StatsService
    private let models: ModelsViewModel
    private let modelsOnDiskProvider: @Sendable () async -> Int
    private let navigation: Navigation
    private let now: () -> Date
    /// "Quit VoxFlow" (review M7) — injected, like every other outward action here, instead of
    /// `quit()` reaching into `NSApplication` directly; defaults to the real thing so production
    /// wiring doesn't need to pass anything.
    private let terminate: () -> Void
    /// `pausedUntilText`'s locale (review B1) — a fixed `dateFormat` with no locale inherits
    /// whatever the current process happens to run under, which is only deterministic in a test if
    /// the test also pins it; defaults to `.current` so a 24-hour-clock user sees "22:41" and a
    /// 12-hour-clock user sees "10:41 AM", not a Latin-digit assumption baked into the app.
    private let locale: Locale

    /// Refreshed by `refresh()` (an actor hop away, via `modelsOnDiskProvider`) rather than read
    /// synchronously — the dropdown's `.task { await viewModel.refresh() }` populates it each time
    /// the menu opens.
    private(set) var modelsOnDisk = 0

    init(dictation: DictationCoordinator, settings: DictationSettings, stats: StatsService, models: ModelsViewModel,
         modelsOnDisk: @escaping @Sendable () async -> Int, navigation: Navigation, now: @escaping () -> Date = { Date() },
         locale: Locale = .current, terminate: @escaping () -> Void = { NSApplication.shared.terminate(nil) }) {
        self.dictation = dictation
        self.settings = settings
        self.stats = stats
        self.models = models
        self.modelsOnDiskProvider = modelsOnDisk
        self.navigation = navigation
        self.now = now
        self.locale = locale
        self.terminate = terminate
    }

    func refresh() async {
        modelsOnDisk = await modelsOnDiskProvider()
    }

    // MARK: Status (header)

    var isPaused: Bool { dictation.pausedUntil != nil }

    /// MB-02's condensed dropdown (paused, or a model actively downloading) drops hands-free/stats
    /// and the History/pause/language items — ruling 6: "MB-02 variant when paused (…) or
    /// downloading (…)". `MenuBarView` reads this instead of re-deriving the OR itself.
    var isCondensed: Bool { isPaused || downloading != nil }

    /// "Ready · on-device" / "Listening…" / "Cleaning up…" / "Paused until 10:41" (design MB-01/02).
    var statusText: String {
        if let pausedUntilText { return "Paused until \(pausedUntilText)" }
        return MenuBarStatus.text(for: dictation.state)
    }
    var statusColor: Color { MenuBarStatus.dotColor(for: dictation.state) }

    /// "10:41" — the wall-clock time `pause(for:)` ends, `nil` outside `.paused`. Computed from
    /// `now()` (this view model's injected wall clock, test-controllable) plus the coordinator's own
    /// monotonic `pausedUntil`/`now()` pair, rather than `dictation.pausedUntilDate` directly, so
    /// `MenuBarViewModelTests` can pin the exact "10:41" text deterministically.
    var pausedUntilText: String? {
        guard let until = dictation.pausedUntil else { return nil }
        let wallClockEnd = now().addingTimeInterval(until - dictation.now())
        return timeFormatter.string(from: wallClockEnd)
    }

    // MARK: Hands-free toggle

    var handsFree: Bool {
        get { settings.hotkeyMode == .handsFree }
        set { settings.hotkeyMode = newValue ? .handsFree : .pushToTalk }
    }

    // MARK: Stats row

    /// "1,240 words today" (design MB-01 stats row).
    var wordsTodayText: String {
        "\(Self.numberFormatter.string(from: NSNumber(value: stats.today.words)) ?? "\(stats.today.words)") words today"
    }
    /// "18 min saved".
    var minutesSavedText: String { "\(stats.today.minutesSaved) min saved" }

    // MARK: Downloading (MB-02)

    /// The first row (speech, then style) actively downloading, or `nil` — MB-02's "Downloading
    /// {model} · 62%". Pulled out as a pure static function so it's testable against hand-built
    /// `ModelsViewModel.Row` values, without driving a real download through `ModelsViewModel`.
    var downloading: (name: String, percent: Int)? { Self.downloadingRow(in: models.speechRows + models.styleRows) }

    static func downloadingRow(in rows: [ModelsViewModel.Row]) -> (name: String, percent: Int)? {
        for row in rows {
            if case .downloading(let written, let total) = row.state, total > 0 {
                return (row.model.displayName, Int((Double(written) / Double(total) * 100).rounded()))
            }
        }
        return nil
    }

    // MARK: Language

    var languageName: String { Self.languages.first { $0.code == settings.language }?.label ?? "Auto-detect" }
    func setLanguage(_ code: String?) { settings.language = code }

    // MARK: Footer

    // Reads `settings.hotkeyMode` directly (not `dictation.hotkeyMode`, which mirrors the *same*
    // settings only in production wiring) — one source of truth this view model already holds,
    // same as `handsFree`.
    var modeText: String { settings.hotkeyMode == .handsFree ? "Hands-free" : "Push-to-talk" }
    /// "No network connections · 3 models on disk · Push-to-talk" (design MB-01 footer).
    var footer: String { "No network connections · \(modelsOnDisk) models on disk · \(modeText)" }

    // MARK: Actions

    /// FB-09 "Pause dictation for 1 hour".
    func pauseOneHour() { dictation.pause(for: Self.pauseDuration) }
    func resume() { dictation.resume() }
    func openMain() { navigation.requestMainWindow = true }
    func openHistory() {
        navigation.page = .history
        navigation.requestMainWindow = true
    }
    func openSettings() {
        navigation.page = .settings
        navigation.requestMainWindow = true
    }
    func quit() { terminate() }

    /// "10:41" (24-hour locales) / "10:41 AM" (12-hour locales) — built from the `"jmm"` skeleton
    /// (hour-without-leading-zero + minutes) against `locale`, not a bare `"h:mm"` (review B1):
    /// a fixed format string is only deterministic under a fixed locale, and `"h:mm"` also silently
    /// dropped AM/PM on a 24-hour-clock reader with no way to tell 10:41 from 22:41. An instance
    /// property (not `static`), since `locale` is now injected per view model.
    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: locale) ?? "H:mm"
        return formatter
    }

    /// "1,240" — the canvas's exact grouping ("," not locale-dependent); deliberate per design copy,
    /// same reasoning `ResultViewModel.wordCountFormatter` documents for its own fixed "13,842" (review M8).
    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        return formatter
    }()
}
