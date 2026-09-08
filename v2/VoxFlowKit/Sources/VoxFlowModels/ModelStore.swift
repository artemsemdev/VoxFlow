import Foundation
import VoxFlowCore

public enum ModelState: Sendable, Equatable {
    case notInstalled
    case downloading(bytesWritten: Int64, total: Int64)
    /// A partial file is on disk; `install` resumes from it.
    case paused(bytesWritten: Int64, total: Int64)
    case verifying
    case installed
}

public enum ModelStoreError: Error, Equatable, Sendable {
    case unknownModel(String)
    case checksumUnknown(String)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case downloadInterrupted(bytesWritten: Int64)
    case downloadFailed(String)
    case checksumMismatch
    case notInstalled(String)
    case cannotRemoveOnlyModel(String)
    case alreadyInProgress(String)
    case http(status: Int)
}

/// Owns the model files on disk (design ST-03, ST-03v, ST-03d, SYS-DISK, ONB-04a).
/// Installed = the file exists with its expected size and, at install time, its SHA-256 matched.
public actor ModelStore {
    /// Kept free beyond the model size before a download starts (design SYS-DISK: "plus 500 MB").
    public static let reserveBytes: Int64 = 500 * 1024 * 1024

    public let directory: URL
    private let catalog: [ModelDescriptor]
    private let downloader: any ModelDownloading
    private let freeSpace: any FreeSpaceProviding
    private let settings: any KeyValueStore
    private let fileManager = FileManager.default
    private var inProgress: [String: ModelState] = [:]

    public init(directory: URL, catalog: [ModelDescriptor] = ModelCatalog.all, downloader: any ModelDownloading,
                freeSpace: any FreeSpaceProviding, settings: any KeyValueStore) {
        self.directory = directory
        self.catalog = catalog
        self.downloader = downloader
        self.freeSpace = freeSpace
        self.settings = settings
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Production location: ~/Library/Application Support/VoxFlow/Models.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoxFlow/Models", isDirectory: true)
    }

    // MARK: Queries

    public func state(of id: String) -> ModelState {
        if let active = inProgress[id] { return active }
        guard let model = descriptor(id) else { return .notInstalled }
        if fileSize(installedURL(model)) == model.sizeInBytes { return .installed }
        if let partial = fileSize(partialURL(model)), partial > 0 {
            guard partial <= model.sizeInBytes else { return .notInstalled }
            return .paused(bytesWritten: partial, total: model.sizeInBytes)
        }
        return .notInstalled
    }

    public func installedModels(role: ModelRole) -> [ModelDescriptor] {
        catalog.filter { $0.role == role && state(of: $0.id) == .installed }
    }

    /// The persisted default if it is installed, else the catalog default if installed, else the
    /// first installed model of that role, else nil.
    public func defaultModel(role: ModelRole) -> ModelDescriptor? {
        let installed = installedModels(role: role)
        if let saved = settings.string(forKey: Self.defaultKey(role)), let model = installed.first(where: { $0.id == saved }) {
            return model
        }
        return installed.first(where: \.isDefault) ?? installed.first
    }

    public func setDefault(id: String) throws {
        guard let model = descriptor(id) else { throw ModelStoreError.unknownModel(id) }
        guard state(of: id) == .installed else { throw ModelStoreError.notInstalled(id) }
        settings.set(id, forKey: Self.defaultKey(model.role))
    }

    // MARK: Install

    /// Streams states until `.installed`, or throws a `ModelStoreError`.
    public func install(id: String) -> AsyncThrowingStream<ModelState, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performInstall(id: id, emit: { continuation.yield($0) })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performInstall(id: String, emit: @Sendable @escaping (ModelState) -> Void) async throws {
        if inProgress[id] != nil { throw ModelStoreError.alreadyInProgress(id) }
        guard let model = descriptor(id) else { throw ModelStoreError.unknownModel(id) }
        guard !model.sha256.isEmpty else { throw ModelStoreError.checksumUnknown(id) }
        if state(of: id) == .installed { emit(.installed); return }

        let partial = partialURL(model)
        var alreadyHave = fileSize(partial) ?? 0
        if alreadyHave > model.sizeInBytes {
            try? fileManager.removeItem(at: partial)
            alreadyHave = 0
        }
        let required = model.sizeInBytes - alreadyHave + Self.reserveBytes
        let available = try freeSpace.availableBytes(at: directory)
        guard available >= required else {
            throw ModelStoreError.insufficientDiskSpace(required: required, available: available)
        }

        inProgress[id] = .downloading(bytesWritten: alreadyHave, total: model.sizeInBytes)
        defer { inProgress[id] = nil }
        do {
            try await downloader.download(model.downloadURL, to: partial) { written, _ in
                emit(.downloading(bytesWritten: written, total: model.sizeInBytes))
            }
        } catch DownloadError.offline(let written) {
            throw ModelStoreError.downloadInterrupted(bytesWritten: written)
        } catch DownloadError.http(let status) {
            throw ModelStoreError.http(status: status)
        } catch DownloadError.cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ModelStoreError.downloadFailed(String(describing: error))
        }

        inProgress[id] = .verifying
        emit(.verifying)
        let digest = try await Task.detached(priority: .utility) { try SHA256File.hexDigest(of: partial) }.value
        guard digest == model.sha256.lowercased() else {
            try? fileManager.removeItem(at: partial)
            throw ModelStoreError.checksumMismatch
        }
        let destination = installedURL(model)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: partial, to: destination)
        inProgress[id] = nil
        emit(.installed)
    }

    // MARK: Remove

    public func remove(id: String) throws {
        guard let model = descriptor(id) else { throw ModelStoreError.unknownModel(id) }
        guard state(of: id) == .installed else { throw ModelStoreError.notInstalled(id) }
        let others = installedModels(role: model.role).filter { $0.id != id }
        // Design ST-03d: the last installed *speech* model cannot be removed (dictation would stop
        // working); style models can, the app then falls back to rule-based cleanup.
        if model.role == .speech, others.isEmpty { throw ModelStoreError.cannotRemoveOnlyModel(id) }
        let wasDefault = defaultModel(role: model.role)?.id == id
        try fileManager.removeItem(at: installedURL(model))
        try? fileManager.removeItem(at: partialURL(model))
        if wasDefault {
            settings.set(others.first(where: \.isDefault)?.id ?? others.first?.id, forKey: Self.defaultKey(model.role))
        }
    }

    /// ST-03o "Cancel download": deletes the `.partial` file outright (unlike a plain cancel of
    /// `install`, which keeps it so a later `install` resumes). Refuses while an install is actually
    /// running — the caller should cancel that first.
    public func discardDownload(id: String) throws {
        guard let model = descriptor(id) else { throw ModelStoreError.unknownModel(id) }
        guard inProgress[id] == nil else { throw ModelStoreError.alreadyInProgress(id) }
        try? fileManager.removeItem(at: partialURL(model))
    }

    // MARK: Helpers

    private static func defaultKey(_ role: ModelRole) -> String { "models.default.\(role.rawValue)" }
    private func descriptor(_ id: String) -> ModelDescriptor? { catalog.first { $0.id == id } }
    private func installedURL(_ model: ModelDescriptor) -> URL { directory.appendingPathComponent(model.fileName) }
    private func partialURL(_ model: ModelDescriptor) -> URL { directory.appendingPathComponent(model.fileName + ".partial") }
    private func fileSize(_ url: URL) -> Int64? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64)
    }
}
