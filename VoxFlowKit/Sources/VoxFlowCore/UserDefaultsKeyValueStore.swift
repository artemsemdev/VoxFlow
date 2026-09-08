import Foundation

/// `KeyValueStore` over `UserDefaults`, all keys namespaced with `prefix`.
public struct UserDefaultsKeyValueStore: KeyValueStore, @unchecked Sendable {
    // UserDefaults is thread-safe (Apple docs).
    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "voxflow.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func string(forKey key: String) -> String? { defaults.string(forKey: prefix + key) }

    public func set(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: prefix + key) } else { defaults.removeObject(forKey: prefix + key) }
    }
}
