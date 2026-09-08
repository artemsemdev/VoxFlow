import Foundation

public enum ModelRole: String, Sendable, Codable, CaseIterable {
    case speech
    case style
}

/// A downloadable model as listed in the catalog (design ST-03).
public struct ModelDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let role: ModelRole
    public let downloadURL: URL
    public let sizeInBytes: Int64
    /// Lowercase hex SHA-256 of the file; verified before the model counts as installed.
    public let sha256: String
    public let languagesSummary: String
    public let isDefault: Bool

    public init(id: String, displayName: String, role: ModelRole, downloadURL: URL, sizeInBytes: Int64,
                sha256: String, languagesSummary: String, isDefault: Bool) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.downloadURL = downloadURL
        self.sizeInBytes = sizeInBytes
        self.sha256 = sha256
        self.languagesSummary = languagesSummary
        self.isDefault = isDefault
    }

    public var fileName: String { downloadURL.lastPathComponent }
}

public enum DownloadError: Error, Equatable, Sendable {
    /// Network went away; `bytesWritten` are safely on disk and a later call resumes from there.
    case offline(bytesWritten: Int64)
    case http(status: Int)
    case cancelled
}

/// Downloads one URL to one file, appending to an existing partial file (HTTP Range).
public protocol ModelDownloading: Sendable {
    /// `progress(bytesWritten, totalBytes)` is called as data lands. Throws `DownloadError`.
    func download(_ url: URL, to destination: URL, progress: @Sendable @escaping (Int64, Int64) -> Void) async throws
}

public protocol FreeSpaceProviding: Sendable {
    func availableBytes(at directory: URL) throws -> Int64
}

/// Minimal persisted settings surface (UserDefaults in production).
public protocol KeyValueStore: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}
