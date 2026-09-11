import VoxFlowStorage
@testable import VoxFlow

/// Fakes both seams `MCPViewModel` depends on (`MCPServerControlling`, `MCPClientStoreProviding`)
/// in one object — mirrors the real `MCPServerService`, which conforms to both for the same reason
/// (a single shared `MCPClientStore`, see its own doc). `@MainActor`: both protocols are.
@MainActor
final class FakeMCPServer: MCPServerControlling, MCPClientStoreProviding {
    private(set) var boundPort: UInt16?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var clearSessionDecisionsCount = 0
    /// Set to make the next (and every subsequent) `start()` throw — `MCPViewModelTests` exercises
    /// `MCPServerError.noFreePort` specifically, matching what the real `LoopbackListener` throws.
    var startError: (any Error)?
    var portToReturn: UInt16 = 7331
    var onStart: (() async throws -> Void)?

    private let store: MCPClientStore

    init(store: MCPClientStore) {
        self.store = store
    }

    func start() async throws {
        startCount += 1
        try await onStart?()
        if let startError { throw startError }
        boundPort = portToReturn
    }

    func stop() async {
        stopCount += 1
        boundPort = nil
    }

    func clearSessionDecisions() async { clearSessionDecisionsCount += 1 }

    func resolvedClientStore() async -> MCPClientStore { store }
}
