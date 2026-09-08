import Foundation

/// A unique directory under the system temporary folder, removed on `deinit`.
public final class TemporaryDirectory: Sendable {
    public let url: URL

    public init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    public func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}
