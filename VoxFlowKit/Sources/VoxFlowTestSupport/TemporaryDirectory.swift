import Foundation

/// A unique directory under the system temporary folder, removed on `deinit`.
public final class TemporaryDirectory: Sendable {
    public let url: URL
    private let beforeRemoval: @Sendable (URL) -> Void

    public init(beforeRemoval: @escaping @Sendable (URL) -> Void = { _ in }) {
        self.beforeRemoval = beforeRemoval
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        beforeRemoval(url)
        try? FileManager.default.removeItem(at: url)
    }

    public func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}
