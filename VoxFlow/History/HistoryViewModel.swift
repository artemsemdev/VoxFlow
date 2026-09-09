import Foundation
import Synchronization
import SwiftUI
import VoxFlowCore
import VoxFlowFiles
import VoxFlowStorage

/// State and rules of the History page (design MW-02, MW-02d, MW-02e, MW-02n, T-01). Views render
/// it; nothing else decides.
@Observable @MainActor
final class HistoryViewModel {
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
    static let fetchLimit = 500
    static let unreadableMessage = "Encrypted — turn on 'Encrypt history at rest' to read"

    private(set) var records: [DictationRecord] = []
    var query: String = "" {
        didSet { scheduleSearch() }
    }
    var expandedID: Int64?
    private(set) var pendingDeletion: (record: DictationRecord, index: Int)?
    var toastVisible: Bool { pendingDeletion != nil }
    /// Bound by `HistoryPage`'s `.sheet(isPresented:)` for the "Try it in a scratchpad" button
    /// (design 2d). The sheet itself (`ScratchpadSheet.onAppear`/`onDisappear`) enters/leaves
    /// `AppServices.ephemeralScope`, which is what actually keeps a scratchpad capture out of real
    /// History (I-1/I-2/I-3) — this view model no longer watches dictation state to manage that.
    var isScratchpadPresented = false
    var scratchpadText = ""

    private let service: HistoryService
    private let settings: DictationSettings
    private let navigation: Navigation
    private let clock: any MonotonicClock
    private let pasteboard: any Pasteboard

    /// Boxed outside main-actor isolation so `deinit` (nonisolated) can cancel them without an
    /// isolation assertion — same pattern as `FilesViewModel.eventTask`.
    private nonisolated let searchTask = Mutex<Task<Void, Never>?>(nil)
    private nonisolated let undoTask = Mutex<Task<Void, Never>?>(nil)

    init(service: HistoryService, settings: DictationSettings, navigation: Navigation, clock: any MonotonicClock,
         pasteboard: any Pasteboard = SystemPasteboard()) {
        self.service = service
        self.settings = settings
        self.navigation = navigation
        self.clock = clock
        self.pasteboard = pasteboard
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
        return query.isEmpty ? .noDictations : .noResults(query)
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
        records = await service.fetch(limit: Self.fetchLimit)
    }

    /// Re-fetches respecting whatever `query` currently holds — used by the page's `.task` (fires on
    /// every navigation back to History) so it doesn't clobber an in-progress search with the
    /// unfiltered list while the search field still shows a query.
    func refresh() async {
        if query.isEmpty { await load() } else { await search() }
    }

    func toggleExpanded(id: Int64) {
        expandedID = expandedID == id ? nil : id
    }

    func copy(_ record: DictationRecord) {
        pasteboard.setString(record.text)
    }

    /// Removes the row locally right away (design T-01: "row collapses immediately"), issues the
    /// store delete, and arms a 6 s undo window.
    func delete(_ record: DictationRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records.remove(at: index)
        if expandedID == record.id { expandedID = nil }
        pendingDeletion = (record, index)
        Task { await service.delete(id: record.id) }
        armUndoTimer()
    }

    /// Reinserts the pending deletion (a new id — `HistoryService.reinsert` always inserts fresh)
    /// back at the index it was removed from. A no-op once the 6 s window has already cleared it.
    func undo() {
        guard let pending = pendingDeletion else { return }
        undoTask.withLock { $0?.cancel(); $0 = nil }
        pendingDeletion = nil
        Task { [weak self] in
            guard let self else { return }
            guard let restored = await self.service.reinsert(pending.record) else { return }
            let index = min(pending.index, self.records.count)
            self.records.insert(restored, at: index)
        }
    }

    func clearSearch() {
        query = ""
    }

    func openPrivacySettings() {
        navigation.page = .settings
        navigation.settingsTab = .privacy
    }

    // MARK: Search debounce

    private func scheduleSearch() {
        searchTask.withLock { $0?.cancel() }
        let task = Task { [weak self] in
            guard let self else { return }
            // An empty query (typed all the way back to nothing, or "Clear search") skips the debounce
            // entirely — waiting 150 ms here would show the wrong empty state in between: `records`
            // still holds the (typically empty) filtered results while `emptyState` already reads
            // `query.isEmpty`, so the view would flash "No dictations yet" before the real list returns.
            if !self.query.isEmpty {
                do { try await self.clock.sleep(for: Self.debounceInterval) } catch { return }
                guard !Task.isCancelled else { return }
            }
            await self.search()
        }
        searchTask.withLock { $0 = task }
    }

    private func search() async {
        let text = query
        let results = text.isEmpty ? await service.fetch(limit: Self.fetchLimit) : await service.search(text)
        guard query == text else { return }   // superseded by a newer query while this one awaited
        records = results
    }

    // MARK: Undo window

    private func armUndoTimer() {
        undoTask.withLock { $0?.cancel() }
        let task = Task { [weak self] in
            guard let self else { return }
            do { try await self.clock.sleep(for: Self.undoWindow) } catch { return }
            self.pendingDeletion = nil
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

    /// The expanded detail's "INSERTED" column header — the style, uppercased, appended when the
    /// record has one ("INSERTED · VERY CASUAL"), "INSERTED" alone otherwise.
    static func detailHeader(for record: DictationRecord) -> String {
        guard let style = record.style, !style.isEmpty else { return "INSERTED" }
        return "INSERTED · \(style.uppercased())"
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
        if let style = record.style, !style.isEmpty { parts.append(style) }
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
