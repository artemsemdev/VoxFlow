import Foundation
import VoxFlowCore
import VoxFlowModels

/// Settings › Models (design ST-03, ST-03v, ST-03d, ST-03o, SYS-DISK). Rows mirror `ModelStore`; alerts are data.
@Observable @MainActor
final class ModelsViewModel {
    struct Row: Identifiable, Equatable {
        let model: ModelDescriptor
        var state: ModelState
        var isDefault: Bool
        var id: String { model.id }
        // `nonisolated` — `Row` is a plain value type with no isolation of its own, and `gigabytes`
        // touches no actor state, so it stays callable from a nonisolated context like this getter.
        var sizeText: String { ModelsViewModel.gigabytes(model.sizeInBytes) }
        var subtitle: String { "\(sizeText) · \(model.languagesSummary)" }
        var isAvailable: Bool { !model.sha256.isEmpty }   // the Qwen row ships in phase 5
    }

    enum Alert: Equatable {
        case insufficientSpace(ModelDescriptor, required: Int64, available: Int64)
        case removeModel(ModelDescriptor)
        case cannotRemoveOnlyModel(ModelDescriptor)
        case downloadFailed(ModelDescriptor, reason: String)
        case offline(ModelDescriptor, bytesWritten: Int64, total: Int64)
    }

    private(set) var speechRows: [Row] = []
    private(set) var styleRows: [Row] = []
    var alert: Alert?
    private(set) var footerText = ""

    private let store: ModelStore
    private let catalog: [ModelDescriptor]
    private var installs: [String: Task<Void, Never>] = [:]

    init(store: ModelStore, catalog: [ModelDescriptor] = ModelCatalog.all) {
        self.store = store
        self.catalog = catalog
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
        speechRows = speech
        styleRows = style
        let directory = await store.directory   // actor-isolated property: needs its own hop
        footerText = "\(Self.gigabytes(installedBytes)) in \(Self.abbreviate(directory)). Downloads happen only when you press Download — VoxFlow never checks for or fetches anything on its own."
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
                guard let self else { return }
                self.alert = .offline(model, bytesWritten: written, total: model.sizeInBytes)
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

    func pause(_ model: ModelDescriptor) { installs[model.id]?.cancel() }
    func resume(_ model: ModelDescriptor) async { await download(model) }

    func requestRemove(_ model: ModelDescriptor) async {
        let others = await store.installedModels(role: model.role).filter { $0.id != model.id }
        if model.role == .speech, others.isEmpty { alert = .cannotRemoveOnlyModel(model) } else { alert = .removeModel(model) }
    }

    func confirmRemove() async {
        guard case .removeModel(let model) = alert else { return }
        alert = nil
        do { try await store.remove(id: model.id) } catch { alert = .downloadFailed(model, reason: String(describing: error)) }
        await refresh()
    }

    /// SYS-DISK: "Use the 480 MB model" — start the smallest speech model instead.
    func useSmallerModelInstead() async {
        guard case .insufficientSpace = alert else { return }
        alert = nil
        if let small = catalog.filter({ $0.role == .speech }).min(by: { $0.sizeInBytes < $1.sizeInBytes }) { await download(small) }
    }

    func dismissAlert() { alert = nil }

    private func setState(_ state: ModelState, for id: String) {
        if let index = speechRows.firstIndex(where: { $0.id == id }) { speechRows[index].state = state }
        if let index = styleRows.firstIndex(where: { $0.id == id }) { styleRows[index].state = state }
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
    static func removeMessage(_ model: ModelDescriptor) -> String {
        "Frees \(gigabytes(model.sizeInBytes)). You can download it again anytime."
    }

    static let cannotRemoveOnlyModelTitle = "This is the only installed speech model"
    static let cannotRemoveOnlyModelMessage = "Download another model before removing it."

    static let offlineTitle = "Download paused — you're offline"
    static func offlineMessage(bytesWritten: Int64, total: Int64) -> String {
        "\(gigabytes(bytesWritten)) of \(gigabytes(total)) saved. It will resume when you're back online."
    }
}
