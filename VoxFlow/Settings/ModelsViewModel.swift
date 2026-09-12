import AppKit
import Foundation
import VoxFlowCore
import VoxFlowFiles
import VoxFlowModels

/// Opens macOS System Settings (SYS-DISK "Free up space…"). A protocol so tests can fake it.
protocol SystemSettingsOpening: Sendable {
    func openStorageSettings()
}

/// Production `SystemSettingsOpening`: deep-links straight to the Storage pane.
struct WorkspaceSystemSettingsOpener: SystemSettingsOpening {
    func openStorageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Settings › Models (design ST-03, ST-03v, ST-03d, ST-03o, SYS-DISK). Rows mirror `ModelStore`; alerts are data.
@Observable @MainActor
final class ModelsViewModel {
    struct Row: Identifiable, Equatable {
        let model: ModelDescriptor
        var state: ModelState
        var isDefault: Bool
        var isLoadingIntoMemory = false
        var id: String { model.id }
        // `nonisolated` — `Row` is a plain value type with no isolation of its own, and `gigabytes`
        // touches no actor state, so it stays callable from a nonisolated context like this getter.
        var sizeText: String { ModelsViewModel.gigabytes(model.sizeInBytes) }
        var subtitle: String { "\(sizeText) · \(model.languagesSummary)" }
        var statusSubtitle: String { isLoadingIntoMemory ? "Loading into memory…" : subtitle }
        var statusContext: String? { isLoadingIntoMemory ? "first use" : nil }
        var isAvailable: Bool { !model.sha256.isEmpty }   // the Qwen row ships in phase 5
    }

    enum Alert: Equatable {
        case insufficientSpace(ModelDescriptor, required: Int64, available: Int64)
        /// `keeps` is the display name of the model dictation falls back to (the remaining default
        /// of the same role), or nil if there isn't one — `removeMessage` omits that clause then.
        case removeModel(ModelDescriptor, keeps: String?)
        case cannotRemoveOnlyModel(ModelDescriptor)
        case downloadFailed(ModelDescriptor, reason: String)
        /// `dictationKeepsWorking` is true when another speech model is already installed.
        case offline(ModelDescriptor, bytesWritten: Int64, total: Int64, dictationKeepsWorking: Bool)
    }

    private(set) var speechRows: [Row] = []
    private(set) var styleRows: [Row] = []
    var alert: Alert?
    private(set) var footerText = ""

    private let store: ModelStore
    private let modelLoader: ModelLoader?
    private let catalog: [ModelDescriptor]
    private let settingsOpener: any SystemSettingsOpening
    private var installs: [String: Task<Void, Never>] = [:]
    private let now: () -> Date
    /// One ETA estimator per actively-downloading row (design 3d's rate/window logic, reused from
    /// `ETAEstimator`); cleared whenever a row leaves `.downloading` for any other state.
    private var estimators: [String: ETAEstimator] = [:]

    init(store: ModelStore, catalog: [ModelDescriptor] = ModelCatalog.all, modelLoader: ModelLoader? = nil,
         settingsOpener: any SystemSettingsOpening = WorkspaceSystemSettingsOpener(), now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.catalog = catalog
        self.modelLoader = modelLoader
        self.settingsOpener = settingsOpener
        self.now = now
    }

    func refresh() async {
        var speech: [Row] = [], style: [Row] = []
        let defaultSpeech = await store.defaultModel(role: .speech)?.id
        let defaultStyle = await store.defaultModel(role: .style)?.id
        var installedBytes: Int64 = 0
        for model in catalog {
            let state = await store.state(of: model.id)
            if state == .installed { installedBytes += model.sizeInBytes }
            let row = Row(model: model, state: state, isDefault: (model.role == .speech ? defaultSpeech : defaultStyle) == model.id)
            if model.role == .speech { speech.append(row) } else { style.append(row) }
        }
        // Race fix: the `await store.state(of:)` calls above each suspend, and `download()`'s own
        // stream-consuming loop (`setState`, below) can advance the *live* row several steps further
        // while this loop is still working through the catalog — or even finish the whole install —
        // before this function reaches its blanket `speechRows = speech` a few lines down. Assigning
        // the array we built from those now-stale reads would silently roll a fast-moving download
        // back to whatever it was partway through. The stream is the source of truth for any model
        // still actively installing, so for those rows, keep whatever `speechRows`/`styleRows` holds
        // *right now* (read as late as possible, i.e. after the loop above, not before it) instead of
        // what was just read from the store.
        let liveStates = Dictionary(uniqueKeysWithValues: (speechRows + styleRows).map { ($0.id, $0.state) })
        for index in speech.indices where installs[speech[index].id] != nil {
            if let live = liveStates[speech[index].id] { speech[index].state = live }
        }
        for index in style.indices where installs[style[index].id] != nil {
            if let live = liveStates[style[index].id] { style[index].state = live }
        }
        // Read this after the suspending store loop so a load that started or finished during the
        // refresh cannot be overwritten by an earlier snapshot.
        let loadingModelID = await modelLoader?.loadingModelID
        for index in speech.indices { speech[index].isLoadingIntoMemory = speech[index].id == loadingModelID }
        for index in style.indices { style[index].isLoadingIntoMemory = style[index].id == loadingModelID }
        speechRows = speech
        styleRows = style
        let directory = await store.directory   // actor-isolated property: needs its own hop
        footerText = "\(Self.gigabytes(installedBytes)) in \(Self.abbreviate(directory)). Downloads happen only when you press Download — VoxFlow never checks for or fetches anything on its own."
    }

    func observeModelLoading() async {
        guard let modelLoader else { return }
        let events = await modelLoader.subscribe()
        if let id = await modelLoader.loadingModelID { setLoading(true, modelID: id) }
        for await event in events {
            switch event {
            case .started(let id): setLoading(true, modelID: id)
            case .finished(let id): setLoading(false, modelID: id)
            }
        }
    }

    private func setLoading(_ loading: Bool, modelID: String) {
        if let index = speechRows.firstIndex(where: { $0.id == modelID }) { speechRows[index].isLoadingIntoMemory = loading }
        if let index = styleRows.firstIndex(where: { $0.id == modelID }) { styleRows[index].isLoadingIntoMemory = loading }
    }

    /// Runs the install in a detached-from-`self` task: only `store` (a plain, cycle-free reference)
    /// is captured strongly, and every touch of `self` is behind its own `guard let self else { … }`
    /// so no strong reference to the view model survives a suspension point inside the `for try
    /// await` loop below (same rule `FilesViewModel`'s subscription task follows). Cancelling the
    /// install via `pause` throws `CancellationError` out of the loop — caught below and treated as
    /// "leave the partial alone"; `refresh()` then reports the row as `.paused`.
    func download(_ model: ModelDescriptor) async {
        guard installs[model.id] == nil else { return }
        alert = nil   // starting a fresh attempt (incl. a resume) supersedes any stale alert for this row
        let store = self.store
        let task = Task { [weak self] in
            do {
                for try await state in await store.install(id: model.id) {
                    guard let self else { return }
                    self.setState(state, for: model.id)
                }
            } catch ModelStoreError.insufficientDiskSpace(let required, let available) {
                guard let self else { return }
                self.alert = .insufficientSpace(model, required: required, available: available)
            } catch ModelStoreError.downloadInterrupted(let written) {
                // Dictation still works if some *other* speech model is already installed — this one
                // never finished, so it can't be that other model itself.
                let dictationKeepsWorking = !(await store.installedModels(role: .speech)).isEmpty
                guard let self else { return }
                self.alert = .offline(model, bytesWritten: written, total: model.sizeInBytes, dictationKeepsWorking: dictationKeepsWorking)
            } catch ModelStoreError.checksumMismatch {
                guard let self else { return }
                self.alert = .downloadFailed(model, reason: "The download didn't verify (checksum mismatch). Nothing was installed and the file was deleted.")
            } catch ModelStoreError.http(let status) {
                guard let self else { return }
                self.alert = .downloadFailed(model, reason: "The server answered \(status).")
            } catch is CancellationError {
                // Pause: the partial stays; refresh() shows .paused
            } catch {
                guard let self else { return }
                self.alert = .downloadFailed(model, reason: String(describing: error))
            }
            guard let self else { return }
            self.installs[model.id] = nil
            await self.refresh()
        }
        installs[model.id] = task
        await task.value
    }

    /// ST-03o pause: cancels the store's producer and waits for its cleanup, so the row reads `.paused`
    /// as soon as this returns (the consumer task finishes on its own and refreshes).
    func pause(_ model: ModelDescriptor) async {
        await store.cancelInstall(id: model.id)
        installs[model.id]?.cancel()
    }
    func resume(_ model: ModelDescriptor) async { await download(model) }

    /// ST-03o "Cancel download": discards the partial file outright (vs. `pause`, which keeps it).
    /// A no-op download-wise — nothing is in progress by the time this is offered (the alert only
    /// shows after the install has already failed/stopped), so the downloader is never touched.
    func discardDownload(_ model: ModelDescriptor) async {
        alert = nil
        do {
            try await store.discardDownload(id: model.id)
        } catch ModelStoreError.alreadyInProgress {
            // The row resumed (or a fresh attempt started) between the offline alert appearing and
            // Cancel being pressed — surfaced as its own alert (T4) instead of the discard silently
            // no-op'ing, which would leave the user thinking Cancel did nothing.
            alert = .downloadFailed(model, reason: "The download is still running; pause it first.")
        } catch {
            // Any other failure (e.g. nothing to discard) — refresh() below re-syncs the row either way.
        }
        await refresh()
    }

    /// SYS-DISK "Free up space…".
    func openStorageSettings() { settingsOpener.openStorageSettings() }

    func requestRemove(_ model: ModelDescriptor) async {
        let others = await store.installedModels(role: model.role).filter { $0.id != model.id }
        if model.role == .speech, others.isEmpty {
            alert = .cannotRemoveOnlyModel(model)
        } else {
            let keeps = (others.first(where: \.isDefault) ?? others.first)?.displayName
            alert = .removeModel(model, keeps: keeps)
        }
    }

    func confirmRemove() async {
        guard case .removeModel(let model, _) = alert else { return }
        alert = nil
        do { try await store.remove(id: model.id) } catch { alert = .downloadFailed(model, reason: String(describing: error)) }
        await refresh()
    }

    /// SYS-DISK: "Use the N model" — start the smallest speech model smaller than the one that just
    /// failed instead (the safest bet to actually fit in whatever free space triggered the alert).
    func useSmallerModelInstead() async {
        guard case .insufficientSpace(let failed, _, _) = alert else { return }
        alert = nil
        if let smaller = smallerSpeechModel(than: failed) { await download(smaller) }
    }

    /// The catalog's smallest speech model still smaller than `model` — drives both the SYS-DISK
    /// "Use the N model" button label and `useSmallerModelInstead()` itself, so the two can't drift.
    func smallerSpeechModel(than model: ModelDescriptor) -> ModelDescriptor? {
        catalog.filter { $0.role == .speech && $0.sizeInBytes < model.sizeInBytes }
            .min { $0.sizeInBytes < $1.sizeInBytes }
    }

    func dismissAlert() { alert = nil }

    private func setState(_ state: ModelState, for id: String) {
        if case .downloading(let written, let total) = state, total > 0 {
            var estimator = estimators[id] ?? ETAEstimator()
            estimator.record(progress: Double(written) / Double(total), at: now().timeIntervalSince1970)
            estimators[id] = estimator
        } else {
            estimators[id] = nil
        }
        if let index = speechRows.firstIndex(where: { $0.id == id }) { speechRows[index].state = state }
        if let index = styleRows.firstIndex(where: { $0.id == id }) { styleRows[index].state = state }
    }

    /// "744 MB of 1.2 GB" for a downloading row, plus " · N min left"/" · N s left" once
    /// `ETAEstimator` has enough samples to estimate (design 3d's rate/window logic, F).
    func downloadText(for row: Row) -> String {
        guard case .downloading(let written, let total) = row.state else { return row.subtitle }
        var text = Self.progressText(written: written, total: total)
        if let seconds = estimators[row.id]?.secondsRemaining {
            text += seconds < 60 ? " · \(Int(seconds.rounded())) s left" : " · \(Int((seconds / 60).rounded())) min left"
        }
        return text
    }

    nonisolated static func gigabytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        return gb >= 1 ? String(format: "%.1f GB", gb) : "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }

    static func abbreviate(_ url: URL) -> String { ResultViewModel.abbreviate(url) }

    /// "744 MB of 1.2 GB" for a downloading row (an ETA suffix, if any, is the view's concern).
    static func progressText(written: Int64, total: Int64) -> String {
        "\(gigabytes(written)) of \(gigabytes(total))"
    }

    // MARK: Alert copy (design SYS-DISK, ST-03d, ST-03o)

    static let insufficientSpaceTitle = "Not enough free space"
    static func insufficientSpaceMessage(_ model: ModelDescriptor, available: Int64) -> String {
        "\(model.displayName) needs \(gigabytes(model.sizeInBytes)) plus 500 MB to unpack. This Mac has \(gigabytes(available)) free."
    }

    static func removeTitle(_ model: ModelDescriptor) -> String { "Remove \(model.displayName)?" }
    static func removeMessage(_ model: ModelDescriptor, keeps: String?) -> String {
        var message = "Frees \(gigabytes(model.sizeInBytes))."
        if let keeps { message += " Dictation keeps using \(keeps)." }
        message += " You can download it again anytime."
        return message
    }

    static let cannotRemoveOnlyModelTitle = "This is the only installed speech model"
    static let cannotRemoveOnlyModelMessage = "Download another model before removing it."

    static let offlineTitle = "Download paused — you're offline"
    static func offlineMessage(bytesWritten: Int64, total: Int64, dictationKeepsWorking: Bool) -> String {
        var message = "\(gigabytes(bytesWritten)) of \(gigabytes(total)) saved. It will resume when you're back online."
        if dictationKeepsWorking { message += " Dictation keeps working with your installed model." }
        return message
    }
}
