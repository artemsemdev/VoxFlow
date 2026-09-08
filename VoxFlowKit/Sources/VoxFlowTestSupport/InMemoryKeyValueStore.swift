import Foundation
import VoxFlowCore

public final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    // Guarded by `lock`; the class is a test double and never shares an instance across tests.
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func string(forKey key: String) -> String? {
        lock.withLock { values[key] }
    }

    public func set(_ value: String?, forKey key: String) {
        lock.withLock { values[key] = value }
    }
}
