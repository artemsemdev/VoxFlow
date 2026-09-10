import Foundation
import VoxFlowCore
import VoxFlowDictation
import VoxFlowFiles
import VoxFlowMCP
import VoxFlowStorage

/// What `MCPViewModel` drives instead of the concrete `MCPServerService` — so
/// `MCPViewModelTests` can fake start/stop/boundPort without ever binding a real loopback socket.
/// `@MainActor`: the real implementation is `@MainActor` and every call site (`MCPViewModel`,
/// `AppDelegate`) is already on the main actor.
@MainActor
protocol MCPServerControlling: AnyObject {
    var boundPort: UInt16? { get }
    func start() async throws
    func stop() async
    /// Forgets every session-scoped approval and denial (final review F3) — called when the access
    /// token is regenerated, so an "Allow once" client cannot slip back in without a new dialog.
    func clearSessionDecisions() async
}

/// What `MCPViewModel` reads "Connected clients" through instead of a concrete `MCPClientStore` —
/// same reasoning as `MCPServerControlling`: `MCPClientStore` needs a `VoxFlowDatabase` that isn't
/// available synchronously (see `MCPServerService`'s own doc), so resolving it is `async`, and this
/// seam lets `MCPViewModelTests` hand back an in-memory store instantly instead of waiting on a
/// real `HistoryService` open. `MCPServerService` conforms to both protocols and resolves the very
/// same `MCPClientStore` instance either way is entered first (`start()` or a Settings-page read) —
/// see `resolvedClientStore()`'s own doc.
@MainActor
protocol MCPClientStoreProviding: AnyObject {
    func resolvedClientStore() async -> MCPClientStore
}

/// Owns the loopback MCP server's two moving parts — `LoopbackListener` (transport) and
/// `MCPToolRunner` (protocol routing + the three tools + ST-06a approval) — behind the single
/// `start()`/`stop()`/`boundPort` seam `MCPViewModel` and `AppDelegate` drive.
///
/// `@MainActor`, not merely `Sendable`: `MCPToolRunner` itself is `@MainActor` (see its own doc),
/// so building and holding one here needs the same isolation; `boundPort` is read by
/// `MCPViewModel` (also `@MainActor`) synchronously right after `start()`/`stop()` resolve, with no
/// extra hop needed to stay deterministic in tests. `LoopbackListener` is an `actor`, so the
/// `await listener.start()/.stop()/.boundPort` calls below are this type's only suspension points
/// besides the lazy runner build.
///
/// The `MCPToolRunner`/`LoopbackListener` pair (and the `MCPClientStore` they and `MCPViewModel`
/// share, via `resolvedClientStore()`) is built lazily, on first use, rather than eagerly in
/// `init` — `MCPClientStore` (one of `MCPToolRunner`'s required, non-optional init parameters,
/// fixed by Task 3's committed signature) needs a concrete `VoxFlowDatabase`, and that only becomes
/// available once `historyService.ready()` resolves (async, and deliberately not forced at
/// `AppServices.live()` time — see `HistoryService`'s own doc on why that stays lazy). Resolving
/// lazily keeps `AppServices.live()` fully synchronous (no blocking SQLite I/O on the main thread
/// at construction) while still handing `MCPToolRunner` a real, already-open `MCPClientStore`
/// before any request can reach it.
@MainActor
final class MCPServerService: MCPServerControlling, MCPClientStoreProviding {
    private let settings: MCPSettings
    private let coordinator: DictationCoordinator
    private let controller: DictationController
    private let historyService: HistoryService
    private let fileTranscribing: any FileTranscribing
    private let pathPolicy: PathPolicy
    private let clock: any MonotonicClock
    private let approvalPresenter: any MCPApprovalPresenting
    private let serverVersion: String
    private let resolver: any PeerResolving
    private let portRange: ClosedRange<UInt16>
    /// Injectable only for the integration test's framing-deadline case; production uses the default.
    private let framingDeadline: TimeInterval

    private var clientStore: MCPClientStore?
    private var runner: MCPToolRunner?
    private var listener: LoopbackListener?

    private(set) var boundPort: UInt16?

    init(settings: MCPSettings, coordinator: DictationCoordinator, controller: DictationController,
         historyService: HistoryService, fileTranscribing: any FileTranscribing, pathPolicy: PathPolicy,
         clock: any MonotonicClock, approvalPresenter: any MCPApprovalPresenting, serverVersion: String,
         resolver: any PeerResolving = LibprocPeerResolver(), portRange: ClosedRange<UInt16> = 7331...7340,
         framingDeadline: TimeInterval = ConnectionHandler.defaultFramingDeadline) {
        self.settings = settings
        self.coordinator = coordinator
        self.controller = controller
        self.historyService = historyService
        self.fileTranscribing = fileTranscribing
        self.pathPolicy = pathPolicy
        self.clock = clock
        self.approvalPresenter = approvalPresenter
        self.serverVersion = serverVersion
        self.resolver = resolver
        self.portRange = portRange
        self.framingDeadline = framingDeadline
    }

    /// Resolves (building on first call) the runner, then starts the listener. Publishes the bound
    /// port to both `self` (`MCPViewModel`'s `boundEndpoint`/`portNote`) and `runner.boundPort`
    /// (`MCPHTTPPolicy`'s Origin check — unset until this resolves, same fail-closed reasoning as
    /// the listener's own doc). Throws `MCPServerError.noFreePort` when every port 7331–7340 is
    /// busy; `boundPort` stays `nil` in that case.
    func start() async throws {
        let runner = await resolvedRunner()
        let listener = self.listener ?? LoopbackListener(portRange: portRange, resolver: resolver, handler: runner,
                                                        framingDeadline: framingDeadline)
        self.listener = listener
        try await listener.start()
        let port = await listener.boundPort
        boundPort = port
        if let port { runner.boundPort = port }
    }

    func stop() async {
        guard let listener else { return }
        await listener.stop()
        boundPort = nil
        runner?.boundPort = 0
    }

    /// The single `MCPClientStore` both the runner (approving/recording sightings) and
    /// `MCPViewModel` (reading "Connected clients", revoking) share — resolved once, lazily,
    /// whichever of `start()`/`MCPViewModel.refresh()` gets there first; every later caller (on
    /// either seam) gets back the exact same cached instance rather than a second connection to the
    /// same table.
    ///
    /// `mcp_clients` carries no encryption key of its own (unlike `dictations`) — a history open
    /// failure (e.g. `.keyLost`) must not also take the MCP server's client-approval persistence
    /// down with it, same "degrades gracefully" reasoning `ContentService` already applies to
    /// dictionary/snippets/style overrides on this same connection. Falling back to an in-memory
    /// database on the rare case `historyService.database` is still nil (the underlying SQLite file
    /// itself couldn't even be created) keeps the server usable — approvals just won't survive a
    /// relaunch that launch.
    func resolvedClientStore() async -> MCPClientStore {
        if let clientStore { return clientStore }
        await historyService.ready()
        guard let database = historyService.database ?? (try? VoxFlowDatabase.inMemory()) else {
            // `VoxFlowDatabase.inMemory()`'s only failure mode is GRDB itself being unable to open
            // an in-process SQLite connection — effectively never, on a real Mac. Nothing sound is
            // left to hand back at that point; this never actually fires in practice.
            fatalError("MCPServerService: could not open even an in-memory database for MCPClientStore")
        }
        let store = MCPClientStore(database: database)
        clientStore = store
        return store
    }

    /// Only touches a runner that already exists: if none has been built yet there are no session
    /// decisions to forget, and building one here just to clear it would open the database for
    /// nothing.
    func clearSessionDecisions() async {
        runner?.clearSessionDecisions()
    }

    private func resolvedRunner() async -> MCPToolRunner {
        if let runner { return runner }
        let clientStore = await resolvedClientStore()
        let runner = MCPToolRunner(settings: settings, coordinator: coordinator, controller: controller,
                                   historyService: historyService, fileTranscribing: fileTranscribing, pathPolicy: pathPolicy,
                                   clock: clock, clientStore: clientStore, approvalPresenter: approvalPresenter, serverVersion: serverVersion)
        self.runner = runner
        return runner
    }
}
