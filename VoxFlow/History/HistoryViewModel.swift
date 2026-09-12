import Foundation
import Synchronization
import SwiftUI
import VoxFlowCore
import VoxFlowFiles
import VoxFlowStorage
import VoxFlowStyling

/// State and rules of the History page (design MW-02, MW-02d, MW-02e, MW-02n, T-01). Views render
/// it; nothing else decides.
@Observable @MainActor
final class HistoryViewModel {
    enum DateRange: String, CaseIterable {
        case today = "Today", thisWeek = "This week", thisMonth = "This month", allTime = "All time"

        func includes(_ date: Date, now: Date, calendar: Calendar) -> Bool {
            let component: Calendar.Component
            switch self {
            case .today: component = .day
            case .thisWeek: component = .weekOfYear
            case .thisMonth: component = .month
            case .allTime: return true
            }
            guard let interval = calendar.dateInterval(of: component, for: now) else { return false }
            return date >= interval.start && date < interval.end
        }
    }

    enum EmptyState: Equatable {
        case noDictations
        case historyOff
        case noResults(String)
        /// `HistoryService.status == .disabled` (I-4): history storage itself is unavailable this
        /// session (e.g. the Keychain lost the encryption key) — every dictation is silently not
        /// being saved, and rows that already exist on disk can't be read from here either, so this
        /// must outrank `.noDictations`, which would otherwise claim there's simply nothing yet.
        /// `reason` is already the human-readable copy (see `HistoryViewModel.readableReason`).
        case unavailable(reason: String)
    }

    static let debounceInterval: TimeInterval = 0.15
    static let undoWindow: TimeInterval = 6
    static let unreadableMessage = "Encrypted — turn on 'Encrypt history at rest' to read"

    private(set) var records: [DictationRecord] = []
    private var allRecords: [DictationRecord] = []
    private var searchResults: [DictationRecord] = []
    private var appliedQuery = ""
    private var searchGeneration = 0
    private var deletionTask: Task<Void, Never>?
    var selectedApp: String? { didSet { applyFilters() } }
    var dateRange: DateRange { didSet { applyFilters() } }
    var availableApps: [String] {
        Array(Set(allRecords.map(Self.appLabel))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var query: String = "" {
        didSet { scheduleSearch() }
    }
    var expandedID: Int64?
    private(set) var pendingDeletion: (record: DictationRecord, index: Int, query: String)?
    var toastVisible: Bool { pendingDeletion != nil }
    /// Bound by `HistoryPage`'s `.sheet(isPresented:)` for the "Try it in a scratchpad" button
    /// (design 2d). The sheet itself (`ScratchpadSheet.onAppear`/`onDisappear`) enters/leaves
    /// `AppServices.ephemeralScope`, which is what actually keeps a scratchpad capture out of real
    /// History (I-1/I-2/I-3) — this view model no longer watches dictation state to manage that.
    var isScratchpadPresented = false
    var scratchpadText = ""
    /// The id of the row a Re-style (MW-02s) is currently rewriting, `nil` otherwise — single-flight
    /// (see `restyle(_:to:)`) and what `HistoryRowView` reads to swap the chevron for a spinner and
    /// disable the action strip.
    private(set) var restylingID: Int64?
    private(set) var editingID: Int64?
    var editedText = ""
    private(set) var editError: String?
    private(set) var isSavingEdit = false
    private var originalEditText = ""
    var canSaveEdit: Bool { editingID != nil && !isSavingEdit && editedText != originalEditText }
    var editSaveTitle: String { isSavingEdit ? "Saving…" : "Save" }

    private let service: HistoryService
    private let settings: DictationSettings
    private let navigation: Navigation
    private let clock: any MonotonicClock
    private let pasteboard: any Pasteboard
    private let calendar: Calendar
    private let now: () -> Date
    private let deleteRecord: (Int64) async -> Void
    private let searchRecords: (String) async -> [DictationRecord]
    private let updateText: (Int64, String) async -> DictationRecord?
    /// Injected (not built here) so tests swap in a `FakeLLMBackend`-backed one — defaults to a
    /// rule-only styler so existing call sites (and every test that doesn't care about Re-style)
    /// keep compiling unchanged.
    let restyler: Restyler

    /// Boxed outside main-actor isolation so `deinit` (nonisolated) can cancel them without an
    /// isolation assertion — same pattern as `FilesViewModel.eventTask`.
    private nonisolated let searchTask = Mutex<Task<Void, Never>?>(nil)
    private nonisolated let undoTask = Mutex<Task<Void, Never>?>(nil)

    init(service: HistoryService, settings: DictationSettings, navigation: Navigation, clock: any MonotonicClock,
         pasteboard: any Pasteboard = SystemPasteboard(),
         restyler: Restyler = Restyler(styler: RuleStyler(),
                                       settings: StylingSettingsBox(StylingSettingsSnapshot(
                                           defaultStyle: .casual, removeFillers: true, autoPunctuate: true, snippetSayPrefix: false))),
         calendar: Calendar = .current, now: @escaping () -> Date = Date.init,
         initialDateRange: DateRange = .allTime,
         deleteRecord: ((Int64) async -> Void)? = nil,
         searchRecords: ((String) async -> [DictationRecord])? = nil,
         updateText: ((Int64, String) async -> DictationRecord?)? = nil) {
        self.service = service
        self.settings = settings
        self.navigation = navigation
        self.clock = clock
        self.pasteboard = pasteboard
        self.restyler = restyler
        self.calendar = calendar
        self.now = now
        self.dateRange = initialDateRange
        self.deleteRecord = deleteRecord ?? { await service.delete(id: $0) }
        self.searchRecords = searchRecords ?? { await service.search($0) }
        self.updateText = updateText ?? { await service.updateText(id: $0, text: $1) }
    }

    deinit {
        searchTask.withLock { $0?.cancel() }
        undoTask.withLock { $0?.cancel() }
    }

    // MARK: Derived state

    var emptyState: EmptyState? {
        // Skips the service's transient startup placeholder (`HistoryService.notOpenedYetReason`) —
        // that's not a real failure, just "no one has touched history yet this launch", and would
        // otherwise flash "History is unavailable" for every user during the first `load()`/`refresh()`.
        if case .disabled(let reason) = service.status, reason != HistoryService.notOpenedYetReason {
            return .unavailable(reason: Self.readableReason(reason))
        }
        guard settings.keepHistory else { return .historyOff }
        guard records.isEmpty else { return nil }
        return query.isEmpty && allRecords.isEmpty ? .noDictations : .noResults(query)
    }

    /// I-4: `HistoryService.Status.disabled(reason:)`'s reason is written for the log
    /// (`"history key lost"`, or an arbitrary `String(describing: error)`) — this maps the one case
    /// with a known, common cause to copy a user can act on; anything else is shown as-is rather than
    /// hidden, since even an unrecognized reason is better than none.
    static func readableReason(_ raw: String) -> String {
        raw == "history key lost" ? "The history key could not be found in your Keychain" : raw
    }

    var footerText: String {
        let days = settings.retentionDays
        let tail = days == 0 ? "until you delete it" : "for \(days) \(days == 1 ? "day" : "days")"
        let lead = settings.encryptHistory ? "History is encrypted on this Mac and kept \(tail)." : "History is kept on this Mac \(tail)."
        return lead + " Change in Settings → Privacy."
    }

    // MARK: Actions

    func load() async {
        await search()
    }

    /// Re-fetches respecting whatever `query` currently holds — used by the page's `.task` (fires on
    /// every navigation back to History) so it doesn't clobber an in-progress search with the
    /// unfiltered list while the search field still shows a query.
    func refresh() async {
        await search()
    }

    func toggleExpanded(id: Int64) {
        guard editingID == nil else { return }
        expandedID = expandedID == id ? nil : id
    }

    func copy(_ record: DictationRecord) {
        pasteboard.setString(record.text)
    }

    /// Removes the row locally right away (design T-01: "row collapses immediately"), issues the
    /// store delete, and arms a 6 s undo window.
    func delete(_ record: DictationRecord) {
        guard !isSavingEdit, records.contains(where: { $0.id == record.id }) else { return }
        // An open draft can remain visible outside the query. Its restored row will still pass
        // through the current filters, so it needs no position in the nonmatching search results.
        let index = searchResults.firstIndex(where: { $0.id == record.id }) ?? 0
        if editingID == record.id { cancelEdit(refresh: false) }
        searchGeneration += 1
        records.removeAll { $0.id == record.id }
        searchResults.removeAll { $0.id == record.id }
        allRecords.removeAll { $0.id == record.id }
        if expandedID == record.id { expandedID = nil }
        pendingDeletion = (record, index, appliedQuery)
        let previous = deletionTask
        deletionTask = Task { [deleteRecord] in
            await previous?.value
            await deleteRecord(record.id)
        }
        scheduleSearch(debounce: false)
        armUndoTimer()
    }

    /// Reinserts the pending deletion (a new id — `HistoryService.reinsert` always inserts fresh)
    /// back at the index it was removed from. A no-op once the 6 s window has already cleared it.
    func undo() {
        guard let pending = pendingDeletion else { return }
        undoTask.withLock { $0?.cancel(); $0 = nil }
        pendingDeletion = nil
        let deletion = deletionTask
        Task { [weak self] in
            guard let self else { return }
            await deletion?.value
            guard let restored = await self.service.reinsert(pending.record) else { return }
            await self.refresh()
            // Fresh IDs sort ahead of tied timestamps. Preserve the original position within the
            // same query, then apply the user's current app/date filters to the restored cache.
            if self.appliedQuery == pending.query, self.query == pending.query,
               let index = self.searchResults.firstIndex(where: { $0.id == restored.id }) {
                self.searchResults.remove(at: index)
                self.searchResults.insert(restored, at: min(pending.index, self.searchResults.count))
                self.applyFilters()
            }
        }
    }

    func clearSearch() {
        query = ""
    }

    func searchAllTime() {
        dateRange = .allTime
    }

    static func appLabel(_ record: DictationRecord) -> String {
        guard let name = record.appName, !name.isEmpty else { return "Unknown app" }
        return name
    }

    static func noResultsTitle(query: String) -> String {
        query.isEmpty ? "No dictations match these filters" : "No dictations match “\(query)”"
    }

    func canEdit(_ record: DictationRecord) -> Bool {
        !record.isUnreadable && restylingID == nil && editingID == nil && !isSavingEdit
    }

    func beginEditing(_ record: DictationRecord) {
        guard canEdit(record) else { return }
        searchTask.withLock { $0?.cancel() }
        editingID = record.id
        expandedID = record.id
        editedText = record.text
        originalEditText = record.text
        editError = nil
    }

    func cancelEdit(refresh: Bool = true) {
        guard !isSavingEdit else { return }
        editingID = nil
        editedText = ""
        originalEditText = ""
        editError = nil
        applyFilters()
        if refresh { scheduleSearch() }
    }

    func saveEdit() async {
        guard canSaveEdit, let id = editingID else { return }
        isSavingEdit = true
        defer { isSavingEdit = false }
        guard let updated = await updateText(id, editedText) else {
            editError = "Couldn’t save changes. Your edit is still here."
            return
        }
        // A newer query can supersede refresh. Publish the persisted value before enabling other
        // actions so Delete/Undo cannot snapshot text from before the successful correction.
        records = records.map { $0.id == id ? updated : $0 }
        searchResults = searchResults.map { $0.id == id ? updated : $0 }
        allRecords = allRecords.map { $0.id == id ? updated : $0 }
        editingID = nil
        editedText = ""
        originalEditText = ""
        editError = nil
        await refresh()
    }

    func openPrivacySettings() {
        navigation.page = .settings
        navigation.settingsTab = .privacy
    }

    /// Re-style (design 2e, MW-02s): rewrites `record`'s raw transcript into `style` through
    /// `restyler` (LLM when ready, rules otherwise — `Restyler`'s own fallback), stores the result,
    /// copies it, and refreshes the list so the row's meta line picks up the new style. Single-flight
    /// — a second call while one is already running is a no-op — and a no-op on an unreadable row,
    /// which has no raw text to rewrite. `updateStyled` returning `nil` (the row was deleted out from
    /// under this call) is silently skipped: the canvas has no error UI for Re-style.
    func restyle(_ record: DictationRecord, to style: TextStyle) async {
        guard restylingID == nil, editingID == nil, !record.isUnreadable else { return }
        restylingID = record.id
        defer { restylingID = nil }
        let styled = await restyler.restyleResult(rawText: record.rawText, to: style)
        guard let updated = await service.updateStyled(id: record.id, text: styled.text, style: style.rawValue,
                                                       removedFillerSpans: styled.removedFillerSpans) else { return }
        pasteboard.setString(updated.text)
        await refresh()
    }

    // MARK: Search debounce

    private func scheduleSearch(debounce: Bool = true) {
        searchGeneration += 1
        searchTask.withLock { $0?.cancel() }
        let shouldDebounce = debounce && !query.isEmpty
        let task = Task { [weak self, clock] in
            // An empty query (typed all the way back to nothing, or "Clear search") skips the debounce
            // entirely — waiting 150 ms here would show the wrong empty state in between: `records`
            // still holds the (typically empty) filtered results while `emptyState` already reads
            // `query.isEmpty`, so the view would flash "No dictations yet" before the real list returns.
            if shouldDebounce {
                do { try await clock.sleep(for: Self.debounceInterval) } catch { return }
                guard !Task.isCancelled else { return }
            }
            await self?.search()
        }
        searchTask.withLock { $0 = task }
    }

    private func search() async {
        searchGeneration += 1
        let generation = searchGeneration
        let text = query
        await deletionTask?.value
        guard generation == searchGeneration, !Task.isCancelled else { return }
        // A blank search includes unreadable rows and the full app catalog, including older apps
        // outside the current date range. Text matching/decryption stays in DictationStore.search.
        let catalog = await searchRecords("")
        guard generation == searchGeneration, !Task.isCancelled else { return }
        let results = text.isEmpty ? catalog : await searchRecords(text)
        guard generation == searchGeneration, query == text, !Task.isCancelled else { return }
        allRecords = catalog
        searchResults = results
        appliedQuery = text
        reconcileEdit()
        applyFilters()
    }

    private func applyFilters() {
        // Keep Save/Cancel reachable if filters or an earlier search change during editing.
        let edited = records.first { $0.id == editingID }
        let date = now()
        records = searchResults.filter {
            (selectedApp == nil || Self.appLabel($0) == selectedApp)
                && dateRange.includes($0.createdAt, now: date, calendar: calendar)
        }
        if let edited, !records.contains(where: { $0.id == edited.id }) { records.insert(edited, at: 0) }
        if let expandedID, !records.contains(where: { $0.id == expandedID }) { self.expandedID = nil }
    }

    /// Search may hide the edited row; only a real deletion may discard its draft on refresh.
    private func reconcileEdit() {
        guard let id = editingID, !isSavingEdit, !allRecords.contains(where: { $0.id == id }) else { return }
        cancelEdit(refresh: false)
    }

    // MARK: Undo window

    private func armUndoTimer() {
        undoTask.withLock { $0?.cancel() }
        let task = Task { [weak self, clock] in
            do { try await clock.sleep(for: Self.undoWindow) } catch { return }
            self?.pendingDeletion = nil
        }
        undoTask.withLock { $0 = task }
    }

    // MARK: Row helpers (design MW-02 row fields)

    /// The row's primary text line — the encrypted placeholder for an unreadable row, its inserted
    /// text otherwise.
    static func displayText(for record: DictationRecord) -> String {
        record.isUnreadable ? unreadableMessage : record.text
    }

    /// The expanded detail's "WHAT YOU SAID" column — the encrypted placeholder for an unreadable
    /// row, its raw transcript otherwise.
    static func displayRawText(for record: DictationRecord) -> String {
        record.isUnreadable ? unreadableMessage : record.rawText
    }

    /// The expanded detail's "INSERTED" column header — the style's display name, uppercased,
    /// appended when the record has one ("INSERTED · VERY CASUAL"), "INSERTED" alone otherwise.
    static func detailHeader(for record: DictationRecord) -> String {
        guard let style = record.style, !style.isEmpty else { return "INSERTED" }
        return "INSERTED · \(styleLabel(style).uppercased())"
    }

    /// The Re-style popover's checkmark row (design 2e): `record.style` decoded back to a
    /// `TextStyle`, defaulting to `.casual` for a nil or unrecognized value — same fallback
    /// `TextStyle.default` already names, kept explicit here since `RestyleMenuView` reads it
    /// directly rather than through `TextStyle.default`.
    static func currentStyle(of record: DictationRecord) -> TextStyle {
        record.style.flatMap(TextStyle.init(rawValue:)) ?? .casual
    }

    /// The Re-style popover's footer copy (design 2e), verbatim from the canvas.
    static let restyleFooter = "Rewrites locally and copies the result"
    /// The Re-style popover's row order (design 2e).
    static let restyleOrder: [TextStyle] = [.formal, .casual, .veryCasual, .verbatim]

    /// I1: `record.style` stores `TextStyle.rawValue` (e.g. `"veryCasual"`); rows must show the
    /// human display name (`"Very casual"`) instead. Falls back to the raw value itself for a style
    /// string `TextStyle` no longer recognizes, so an unrecognized value degrades to "shown as-is"
    /// rather than disappearing.
    static func styleLabel(_ raw: String) -> String {
        TextStyle(rawValue: raw)?.displayName ?? raw
    }

    /// "App · h:mm a · m:ss · N words · Style · LANG" (style omitted when there is none). Time uses
    /// a fixed `en_US_POSIX` locale so tests (and every viewer) see the same "9:26 AM" shape.
    static func metaLine(for record: DictationRecord) -> String {
        let appLabel: String
        if let appName = record.appName, !appName.isEmpty { appLabel = appName } else { appLabel = "Unknown app" }
        var parts = [appLabel]
        parts.append(timeFormatter.string(from: record.createdAt))
        parts.append(TimeCode.short(record.duration))
        parts.append("\(record.words) words")
        if let style = record.style, !style.isEmpty { parts.append(styleLabel(style)) }
        if let language = record.language, !language.isEmpty { parts.append(language.uppercased()) }
        return parts.joined(separator: " · ")
    }

    static func initial(for appName: String?) -> String {
        guard let first = appName?.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(first).uppercased()
    }

    /// Derived from a stable (non-randomized) hash of the app name — same app always lands on the
    /// same tile colour, but there's no lookup table, so an app outside the design's four examples
    /// (Slack purple, Mail blue, Notes orange, Xcode blue) still gets a consistent colour.
    static func color(for appName: String?) -> Color {
        guard let appName, !appName.isEmpty else { return .gray }
        var hash: UInt64 = 0
        for byte in appName.utf8 { hash = hash &* 31 &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }

    private static let palette: [Color] = [.purple, .orange, .green, .pink, .indigo, .teal, .red, .blue]

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}
