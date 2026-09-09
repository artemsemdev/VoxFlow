import Synchronization
@testable import VoxFlow

/// In-memory `TokenStoring` for `MCPSettingsTests` — no real Keychain access. `shouldThrow` makes
/// the next `write(_:)` fail, exercising `MCPSettings.token`'s/`regenerate()`'s best-effort
/// swallow. A `final class` (not a `let`-only struct) so it has interior mutability without
/// `@unchecked Sendable`, same `Mutex`-boxed pattern as `FakeLoginItem`.
final class FakeTokenStore: TokenStoring, Sendable {
    private struct State {
        var stored: String?
        var shouldThrow = false
        var writeCount = 0
    }
    private let state: Mutex<State>

    init(stored: String? = nil) {
        state = Mutex(State(stored: stored))
    }

    var writeCount: Int { state.withLock { $0.writeCount } }
    var stored: String? { state.withLock { $0.stored } }

    func setShouldThrow(_ value: Bool) { state.withLock { $0.shouldThrow = value } }

    func read() throws -> String? { state.withLock { $0.stored } }

    func write(_ token: String) throws {
        state.withLock { $0.writeCount += 1 }
        if state.withLock({ $0.shouldThrow }) { throw FakeTokenStoreError.writeFailed }
        state.withLock { $0.stored = token }
    }
}

enum FakeTokenStoreError: Error { case writeFailed }
