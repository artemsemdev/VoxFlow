import Foundation
import VoxFlowCore
import VoxFlowFiles
import VoxFlowModels

/// Completion-only notifications (design MB-03, MB-04; ruling 8): a finished file transcription or
/// a finished model install, posted only while VoxFlow's main window isn't the frontmost, key
/// window. Never posts for a failure — file errors already show inline (MW-06x), and a model
/// install failure already shows its own alert (`ModelsViewModel.Alert`).
///
/// Two sources, two different "just finished" signals:
/// - Files: `ExportCoordinator.onExported` (review I2) — the export's own success signal, not
///   `FileQueue.finished`. The queue event fires the instant transcription finishes, before either
///   of its two independent subscribers (`ExportCoordinator`, this type) has necessarily run, so
///   racing it directly could post "saved to …" before anything was written, with a hard-coded
///   folder, and even when the export itself then failed. Subscribing to the export's own outcome
///   instead means the body is always built from where the file actually landed, and never fires
///   on a failed export.
/// - Models: there is no standalone "install finished" event to subscribe to (`ModelStore.install`'s
///   stream is consumed entirely inside `ModelsViewModel.download(_:)`, one producer per row). The
///   cleanest existing surface is `ModelsViewModel`'s own `@Observable` `speechRows`/`styleRows` —
///   the same rows the Models settings page and the menu bar's MB-02 "Downloading…" already read —
///   watched via `withObservationTracking` (the same re-registration pattern `SoundCoordinator` and
///   `MenuBarServices.observeFirstDictation()` already use) and diffed against the state each row
///   held the *previous* time this fired, so a row is only reported once, on the transition into
///   `.installed`, never for a row that was already installed when this coordinator started.
@MainActor
final class NotificationCoordinator {
    private let posting: any NotificationPosting
    private let isFrontmost: () -> Bool
    private let navigation: Navigation
    private let exports: ExportCoordinator
    private let modelsViewModel: ModelsViewModel
    private let filesViewModel: FilesViewModel

    /// `true` once `authorize()` has been requested — cached so a session that posts many
    /// notifications only ever prompts (or re-reads the cached OS answer) once (ruling 8: "requested
    /// … on the first completion").
    private var didRequestAuthorization = false
    /// The state each model row held the last time `checkModelInstalls()` ran, keyed by model id —
    /// `nil` (no entry yet) means "never observed", which is what keeps a model that was *already*
    /// installed before this coordinator started from firing a spurious notification the first time
    /// `speechRows`/`styleRows` happens to change for an unrelated reason.
    private var previousModelStates: [String: ModelState] = [:]

    init(posting: any NotificationPosting, isFrontmost: @escaping () -> Bool, navigation: Navigation,
         exports: ExportCoordinator, modelsViewModel: ModelsViewModel, filesViewModel: FilesViewModel) {
        self.posting = posting
        self.isFrontmost = isFrontmost
        self.navigation = navigation
        self.exports = exports
        self.modelsViewModel = modelsViewModel
        self.filesViewModel = filesViewModel
    }

    /// Begins both subscriptions — called once, at a real launch (`AppDelegate`, non-test path),
    /// same reasoning as `dictation.start()`/`fnMonitor.start()` right next to it.
    func start() {
        exports.onExported = { [weak self] item, document, url, format in
            self?.handleExported(item: item, document: document, url: url, format: format)
        }
        // Seed `previousModelStates` from whatever's already loaded (typically empty this early —
        // `ModelsViewModel.refresh()` hasn't necessarily run yet) before the first observation
        // registers, so a row that's already `.installed` by the time rows are first read doesn't
        // read as a fresh transition.
        for row in modelsViewModel.speechRows + modelsViewModel.styleRows { previousModelStates[row.id] = row.state }
        observeModelInstalls()
    }

    // MARK: Routing (ruling 8: click → Settings › Models / the Files result)

    /// Wired from `UserNotificationsPoster`'s delegate via a `Sendable` pipe (`AppServices.live()`)
    /// — never called directly by the poster itself, keeping it `Navigation`/`FilesViewModel`-agnostic.
    func handleRoute(_ route: NotificationRoute) {
        navigation.requestMainWindow = true
        switch route {
        case .settingsModels:
            navigation.page = .settings
            navigation.settingsTab = .models
        case .filesResult(let itemID):
            navigation.page = .files
            // `FilesViewModel.open(_:)` is the same call the Files page's own row click makes — if
            // the row is gone (removed since the notification posted), fall back to just opening
            // the Files page itself rather than doing nothing.
            if let item = filesViewModel.items.first(where: { $0.id == itemID }) {
                filesViewModel.open(item)
            }
        }
    }

    // MARK: Files (MB-04)

    /// Wired to `ExportCoordinator.onExported` (review I2) — fires once, only after the file is
    /// actually written, with the URL it was actually written to.
    private func handleExported(item: QueueItem, document: TranscriptDocument, url: URL, format: OutputFormat) {
        guard !isFrontmost() else { return }
        let body = Self.fileBody(item: item, document: document, url: url, format: format)
        Task { await postIfNeeded(AppNotification(body: body, route: .filesResult(itemID: item.id))) }
    }

    /// "{file name} transcribed · {m:ss or h:mm:ss} · {FORMAT} saved to {folder}" (design MB-04,
    /// ruling 8) — `{folder}` is the *actual* exported file's containing folder (review I2, not a
    /// hard-coded "~/Transcripts"), abbreviated the same way Finder/Save panels do. Duration prefers
    /// the item's own (the same number the Files queue row shows while it's running) and falls back
    /// to the document's, in case the file's duration lookup failed to attach to the row for some
    /// reason.
    static func fileBody(item: QueueItem, document: TranscriptDocument, url: URL, format: OutputFormat) -> String {
        let duration = item.duration ?? document.audioDuration
        let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        return "\(item.url.lastPathComponent) transcribed · \(durationText(duration)) · \(format.displayName) saved to \(folder)"
    }

    /// "3:45" under an hour, "1:03:45" at or past one — never zero-padded minutes/hours, always
    /// zero-padded seconds (and minutes, once an hour is showing).
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    // MARK: Models (MB-03)

    private func observeModelInstalls() {
        withObservationTracking {
            _ = modelsViewModel.speechRows
            _ = modelsViewModel.styleRows
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.checkModelInstalls()
                self.observeModelInstalls()
            }
        }
    }

    private func checkModelInstalls() async {
        for row in modelsViewModel.speechRows + modelsViewModel.styleRows {
            let previous = previousModelStates.updateValue(row.state, forKey: row.id)
            guard row.state == .installed, let previous, previous != .installed else { continue }
            guard !isFrontmost() else { continue }
            let body = "\(row.model.displayName) installed. Ready to use offline."
            await postIfNeeded(AppNotification(body: body, route: .settingsModels))
        }
    }

    // MARK: Posting

    private func postIfNeeded(_ notification: AppNotification) async {
        if !didRequestAuthorization {
            didRequestAuthorization = true
            _ = await posting.authorize()
        }
        posting.post(notification)
    }
}
