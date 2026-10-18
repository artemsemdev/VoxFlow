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

/// Service lifecycle tests substitute a transport without opening a socket.
protocol MCPServerTransport: Sendable {
    var boundPort: UInt16? { get async }
    func start() async throws
    func stop() async
}

extension LoopbackListener: MCPServerTransport {}

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
    private let loadDatabase: () async -> VoxFlowDatabase?
    private let makeTransport: (MCPToolRunner) -> any MCPServerTransport

    private var clientStoreTask: Task<MCPClientStore, Never>?
    private var runner: MCPToolRunner?
    private var listener: (any MCPServerTransport)?
    private var inFlightStart: Task<Void, Error>?
    private var generation = 0

    private(set) var boundPort: UInt16?

    /// A client-launched subprocess has no network peer and does not create HTTP approvals.
    /// Handshakes stay independent of the database/Keychain; tools reuse the existing runner.
    func handleStdio(_ request: JSONRPCRequest) async -> Data? {
        guard let id = request.id else { return nil }
        if let version = request.params?["_meta"]?[MCPMetaKey.protocolVersion]?.stringValue,
           !MCPProtocolVersion.supported.contains(version) {
            return try? JSONEncoder().encode(JSONRPCResponse(id: id,
                error: MCPError.unsupportedProtocolVersion(supported: MCPProtocolVersion.supported).jsonRPCError()))
        }
        var enabled: Set<MCPToolID> = []
        if settings.toolTranscribeFile { enabled.insert(.transcribeFile) }
        if settings.toolDictate { enabled.insert(.dictate) }
        if settings.toolSearchHistory { enabled.insert(.searchHistory) }
        let context = MCPRequestContext(enabledTools: enabled, serverVersion: serverVersion)
        let response: JSONRPCResponse
        switch MCPRouter().route(request, context: context) {
        case .accepted: return nil
        case .result(let value): response = JSONRPCResponse(id: id, result: value)
        case .failure(let error, _): response = JSONRPCResponse(id: id, error: error.jsonRPCError())
        case .callTool(let tool, let arguments, _):
            let runner = await resolvedRunner()
            guard !Task.isCancelled else { return nil }
            return await runner.executeStdioTool(tool, arguments: arguments, id: id)
        }
        return try? JSONEncoder().encode(response)
    }

    init(settings: MCPSettings, coordinator: DictationCoordinator, controller: DictationController,
         historyService: HistoryService, fileTranscribing: any FileTranscribing, pathPolicy: PathPolicy,
         clock: any MonotonicClock, approvalPresenter: any MCPApprovalPresenting, serverVersion: String,
         resolver: any PeerResolving = LibprocPeerResolver(), portRange: ClosedRange<UInt16> = 7331...7340,
         framingDeadline: TimeInterval = ConnectionHandler.defaultFramingDeadline,
         loadDatabase: (() async -> VoxFlowDatabase?)? = nil,
         makeTransport: ((MCPToolRunner) -> any MCPServerTransport)? = nil) {
        self.settings = settings
        self.coordinator = coordinator
        self.controller = controller
        self.historyService = historyService
        self.fileTranscribing = fileTranscribing
        self.pathPolicy = pathPolicy
        self.clock = clock
        self.approvalPresenter = approvalPresenter
        self.serverVersion = serverVersion
        self.loadDatabase = loadDatabase ?? {
            await historyService.ready()
            return historyService.database
        }
        self.makeTransport = makeTransport ?? {
            LoopbackListener(portRange: portRange, resolver: resolver, handler: $0, framingDeadline: framingDeadline)
        }
    }

    /// Resolves (building on first call) the runner, then starts the listener. Publishes the bound
    /// port to both `self` (`MCPViewModel`'s `boundEndpoint`/`portNote`) and `runner.boundPort`
    /// (`MCPHTTPPolicy`'s Origin check — unset until this resolves, same fail-closed reasoning as
    /// the listener's own doc). Throws `MCPServerError.noFreePort` when every port 7331–7340 is
    /// busy; `boundPort` stays `nil` in that case.
    func start() async throws {
        if boundPort != nil { return }
        let current = generation
        let ownsStart = inFlightStart == nil
        let task: Task<Void, Error>
        if let pending = inFlightStart {
            task = pending
        } else {
            task = Task { try await self.startListener(generation: current) }
            inFlightStart = task
        }
        // A late joiner must not clear a newer retry after this attempt's creator has returned.
        defer { if ownsStart, generation == current { inFlightStart = nil } }
        do { try await task.value }
        catch {
            guard generation == current else { throw CancellationError() }
            throw error
        }
        guard generation == current else { throw CancellationError() }
    }

    private func startListener(generation current: Int) async throws {
        let runner = await resolvedRunner()
        guard generation == current, !Task.isCancelled else { throw CancellationError() }
        let listener = self.listener ?? makeTransport(runner)
        self.listener = listener
        do {
            try await listener.start()
            guard generation == current else { throw CancellationError() }
            let port = await listener.boundPort
            guard generation == current else { throw CancellationError() }
            boundPort = port
            if let port { runner.boundPort = port }
        } catch {
            // This captured transport may finish after stop detached it. Clean up only that
            // instance, never the replacement belonging to a newer start.
            await listener.stop()
            throw error
        }
    }

    func stop() async {
        generation += 1
        inFlightStart?.cancel()
        inFlightStart = nil
        // Detach before suspension: a fresh start owns a different transport, and an older stop
        // cannot clear its port or stop its connections when its actor hop eventually completes.
        let listener = self.listener
        self.listener = nil
        boundPort = nil
        runner?.boundPort = 0
        await listener?.stop()
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
        if let task = clientStoreTask { return await task.value }
        // Initialization belongs to the service lifetime, independently of start/stop. Settings
        // reads and every startup join this task; cancelling one start must not cancel their store.
        let task = Task { [loadDatabase] in
            guard let database = await loadDatabase() ?? (try? VoxFlowDatabase.inMemory()) else {
                fatalError("MCPServerService: could not open even an in-memory database for MCPClientStore")
            }
            return MCPClientStore(database: database)
        }
        clientStoreTask = task
        return await task.value
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
        if let runner { return runner } // Another caller may have completed initialization while suspended.
        let runner = MCPToolRunner(settings: settings, coordinator: coordinator, controller: controller,
                                   historyService: historyService, fileTranscribing: fileTranscribing, pathPolicy: pathPolicy,
                                   clock: clock, clientStore: clientStore, approvalPresenter: approvalPresenter, serverVersion: serverVersion)
        self.runner = runner
        return runner
    }
}
