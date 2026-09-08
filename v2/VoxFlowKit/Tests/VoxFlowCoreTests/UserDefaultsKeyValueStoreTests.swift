import Foundation
import Testing
@testable import VoxFlowCore

@Suite("UserDefaultsKeyValueStore")
struct UserDefaultsKeyValueStoreTests {
    @Test("round-trips and namespaces keys; nil removes")
    func roundTrip() {
        let suite = "voxflow-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsKeyValueStore(defaults: defaults, prefix: "t.")
        #expect(store.string(forKey: "a") == nil)
        store.set("1", forKey: "a")
        #expect(store.string(forKey: "a") == "1")
        #expect(defaults.string(forKey: "t.a") == "1")
        store.set(nil, forKey: "a")
        #expect(store.string(forKey: "a") == nil)
    }
}
