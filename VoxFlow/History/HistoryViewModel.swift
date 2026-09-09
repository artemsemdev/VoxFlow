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
    /// (design 2d) — starts tracking `dictation.state` while it's up so an armed capture there
    /// doesn't leave a real history entry (ONB-05's `HistoryWriter.suppressNext()` pattern).
    var isScratchpadPresented = false {
        didSet { if isScratchpadPresented { trackDictation() } }
    }
    var scratchpadText = ""

    private let service: HistoryService
    private let settings: DictationSettings
    private let navigation: Navigation
    private let clock: any MonotonicClock
    private let dictation: DictationCoordinator?
    private let historyWriter: HistoryWriter?
    private let pasteboard: any Pasteboard

    /// Boxed outside main-actor isolation so `deinit` (nonisolated) can cancel them without an
    /// isolation assertion — same pattern as `FilesViewModel.eventTask`.
    private nonisolated let searchTask = Mutex<Task<Void, Never>?>(nil)
    private nonisolated let undoTask = Mutex<Task<Void, Never>?>(nil)

    init(service: HistoryService, settings: DictationSettings, navigation: Navigation, clock: any MonotonicClock,
         dictation: DictationCoordinator? = nil, historyWriter: HistoryWriter? = nil, pasteboard: any Pasteboard = SystemPasteboard()) {
        self.service = service
        self.settings = settings
        self.navigation = navigation
        self.clock = clock
        self.dictation = dictation
        self.historyWriter = historyWriter
        self.pasteboard = pasteboard
    }

    deinit {
        searchTask.withLock { $0?.cancel() }
        undoTask.withLock { $0?.cancel() }
    }

    // MARK: Derived state

    var emptyState: EmptyState? {
        guard settings.keepHistory else { return .historyOff }
        guard records.isEmpty else { return nil }
        return query.isEmpty ? .noDictations : .noResults(query)
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
            do { try await self.clock.sleep(for: Self.debounceInterval) } catch { return }
            guard !Task.isCancelled else { return }
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

    // MARK: Scratchpad (ONB-05-style suppress)

    /// Mirrors `OnboardingViewModel.trackDictation`'s `withObservationTracking` pattern, but only
    /// re-registers while the scratchpad sheet is still up — dismissing it (or `deinit`) lets the
    /// chain lapse.
    private func trackDictation() {
        guard let dictation else { return }
        withObservationTracking { _ = dictation.state } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isScratchpadPresented else { return }
                if case .armed = dictation.state { self.historyWriter?.suppressNext() }
                self.trackDictation()
            }
        }
    }

    // MARK: Row helpers (design MW-02 row fields)

    /// The row's primary text line — the encrypted placeholder for an unreadable row, its inserted
    /// text otherwise.
    static func displayText(for record: DictationRecord) -> String {
        record.isUnreadable ? unreadableMessage : record.text
    }

    /// "App · h:mm a · m:ss · N words · Style · LANG" (style omitted when there is none). Time uses
    /// a fixed `en_US_POSIX` locale so tests (and every viewer) see the same "9:26 AM" shape.
    static func metaLine(for record: DictationRecord) -> String {
        var parts = [record.appName?.isEmpty == false ? record.appName! : "Unknown app"]
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
