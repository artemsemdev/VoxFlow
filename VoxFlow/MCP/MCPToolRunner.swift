import Foundation
import VoxFlowCore
import VoxFlowDictation
import VoxFlowFiles
import VoxFlowMCP
import VoxFlowStorage

/// ST-06a: the client-approval dialog seam. `MCPToolRunner` asks this at most once per unapproved
/// client per runner lifetime (session) before letting any tool call through; Task 4 implements the
/// real SwiftUI panel, tests use a fake. `tools` are the wire names of every tool enabled right now
/// (for the dialog's "wants access to: …" copy), not just the one tool that triggered the prompt.
protocol MCPApprovalPresenting: Sendable {
    func present(identity: MCPClientIdentity, tools: [String]) async -> MCPClientDecision
}

/// Ties the MCP server's pieces together: `MCPHTTPPolicy` (transport-level validation) →
/// `MCPRouter` (protocol routing) → ST-06a approval → the three tool bodies. The single
/// `MCPRequestHandling` implementation `LoopbackListener`'s `ConnectionHandler` calls.
///
/// `@MainActor` — not merely `Sendable` — because it holds `DictationCoordinator`/`DictationController`/
/// `HistoryService` (see `handle`'s doc on `MCPClientStore`, below, for the one place that would
/// otherwise block this actor). A `@MainActor final class` conforming to a `Sendable`-requiring
/// protocol (`MCPRequestHandling`) is sound here: every stored property is either itself `Sendable`
/// or, like `coordinator`/`controller`/`historyService`, only ever touched from this actor's serial
/// executor — the same reasoning `HistoryService`/`AppServices` already rely on elsewhere in this
/// app, just applied to a type that (unlike those) must also satisfy a `Sendable` protocol
/// requirement so `ConnectionHandler` (a plain `Sendable` class, not the main actor) can hold it.
@MainActor
final class MCPToolRunner: MCPRequestHandling, Sendable {
    private let settings: MCPSettings
    private let coordinator: DictationCoordinator
    private let controller: DictationController
    private let historyService: HistoryService
    private let fileTranscribing: any FileTranscribing
    private let pathPolicy: PathPolicy
    /// The same clock `controller`'s `FlowBarConfig` timers run on — `dictate`'s own timeout
    /// (`maxDuration + processingTimeout`) is measured on it too, so a test drives both with one
    /// `FakeClock` and never sleeps.
    private let clock: any MonotonicClock
    private let clientStore: MCPClientStore
    private let clientRegistry = ClientRegistry()
    private let approvalPresenter: any MCPApprovalPresenting
    private let serverVersion: String
    private let now: @Sendable () -> Date

    private let httpPolicy = MCPHTTPPolicy()
    private let router = MCPRouter()

    /// Set by the composition root once `LoopbackListener.start()` resolves a port (needed for
    /// `MCPHTTPPolicy`'s Origin check). `0` never matches a real Origin, so every browser-style
    /// request is rejected until this is set — same fail-closed default as an unset token would be.
    var boundPort: UInt16 = 0

    /// `(name, path)` keys mirrored from `mcp_clients` for every *persisted* approval, loaded once
    /// per runner lifetime and kept current in memory afterwards (an "Always allow" answer adds to
    /// it directly rather than re-querying). `MCPClientStore` is blocking SQLite I/O (its own doc:
    /// "call this off the main actor") — every access below runs inside `Task.detached`, the same
    /// pattern `HistoryService`/`HistoryWriter` already use to keep blocking store calls off this
    /// actor even though the *caller* (this class) lives on it.
    private var approvedKeys: Set<String>?
    /// Session-only: a "Deny" answer never writes to `mcp_clients` (persistence is opt-in via
    /// "Always allow", never opt-out) but must still stop the presenter being asked again this
    /// session — `ClientRegistry.decision` checks this before `approvedKeys`.
    private var deniedThisSession: Set<String> = []

    init(settings: MCPSettings, coordinator: DictationCoordinator, controller: DictationController,
         historyService: HistoryService, fileTranscribing: any FileTranscribing, pathPolicy: PathPolicy,
         clock: any MonotonicClock, clientStore: MCPClientStore, approvalPresenter: any MCPApprovalPresenting,
         serverVersion: String, now: @escaping @Sendable () -> Date = Date.init) {
        self.settings = settings
        self.coordinator = coordinator
        self.controller = controller
        self.historyService = historyService
        self.fileTranscribing = fileTranscribing
        self.pathPolicy = pathPolicy
        self.clock = clock
        self.clientStore = clientStore
        self.approvalPresenter = approvalPresenter
        self.serverVersion = serverVersion
        self.now = now
    }

    private var enabledTools: Set<MCPToolID> {
        var tools: Set<MCPToolID> = []
        if settings.toolTranscribeFile { tools.insert(.transcribeFile) }
        if settings.toolDictate { tools.insert(.dictate) }
        if settings.toolSearchHistory { tools.insert(.searchHistory) }
        return tools
    }

    func handle(_ request: MCPHTTPRequest, peer: MCPClientIdentity) async -> (status: Int, body: Data?) {
        switch httpPolicy.verdict(for: request, token: settings.token, boundPort: boundPort) {
        case .status(let code, let error):
            return (code, error.flatMap { Self.encode(JSONRPCResponse(id: nil, error: $0)) })
        case .proceed(let rpcRequest):
            // Read fresh every request (not cached at init/start) — so a disabled tool called by
            // name after being turned off is rejected by the router right here, not only kept out
            // of a stale `tools/list` snapshot (test case 5).
            let context = MCPRequestContext(enabledTools: enabledTools, serverVersion: serverVersion)
            switch router.route(rpcRequest, context: context) {
            case .accepted:
                return (202, nil)
            case .result(let value):
                return (200, Self.encode(JSONRPCResponse(id: rpcRequest.id, result: value)))
            case .failure(let error, let id):
                return (error.httpStatus, Self.encode(JSONRPCResponse(id: id, error: error.jsonRPCError())))
            case .callTool(let toolID, let arguments, let id):
                return await handleToolCall(toolID, arguments: arguments, id: id, peer: peer)
            }
        }
    }

    private func handleToolCall(_ toolID: MCPToolID, arguments: JSONValue, id: JSONRPCID?, peer: MCPClientIdentity) async -> (status: Int, body: Data?) {
        // The transport hands an empty `name` when peer resolution fails entirely — this is the one
        // place that substitutes the display copy (Task 2's resolution note); everything downstream
        // (the registry key, the approval dialog, the `mcp_clients` row) sees "Unknown app".
        let identity = peer.name.isEmpty ? MCPClientIdentity(name: "Unknown app", path: peer.path, pid: peer.pid) : peer
        let toolNames = MCPToolID.allCases.filter { enabledTools.contains($0) }.map(\.name)
        guard await authorize(identity, toolNames: toolNames) else {
            return (MCPError.unauthorized.httpStatus, Self.encode(JSONRPCResponse(id: id, error: MCPError.unauthorized.jsonRPCError())))
        }
        let outcome: ToolOutcome
        switch toolID {
        case .transcribeFile: outcome = await transcribeFile(arguments)
        case .dictate: outcome = await dictate()
        case .searchHistory: outcome = await searchHistory(arguments)
        }
        switch outcome {
        case .success(let text):
            return (200, Self.encode(JSONRPCResponse(id: id, result: Self.textContent(text))))
        case .failure(let code, let message, let httpStatus):
            return (httpStatus, Self.encode(JSONRPCResponse(id: id, error: JSONRPCError(code: code, message: message))))
        }
    }

    // MARK: ST-06a approval

    /// `identity` is already the display identity (empty name substituted). Records a sighting for
    /// *every* call (ST-06 "Connected clients" wants every client that ever tried, not only
    /// approved ones — and `recordSighting` never touches `approved`, so this can't silently
    /// de-approve/re-approve anyone; see `MCPClientStore`'s doc), then resolves through
    /// `ClientRegistry.decision` (deniedThisSession → approvedKeys → ask) and, only on `.ask`, calls
    /// the presenter — exactly once, since its answer always lands in one of `approvedKeys`/
    /// `deniedThisSession` before returning, so the *next* call for the same client short-circuits
    /// before ever reaching the presenter again.
    private func authorize(_ identity: MCPClientIdentity, toolNames: [String]) async -> Bool {
        await ensureApprovedKeysLoaded()
        let key = ClientRegistry.key(identity)
        await recordSighting(identity)
        switch clientRegistry.decision(for: identity, approved: approvedKeys ?? [], deniedThisSession: deniedThisSession, allowedOnce: []) {
        case .allow:
            return true
        case .deny:
            return false
        case .ask:
            switch await approvalPresenter.present(identity: identity, tools: toolNames) {
            case .allow:
                approvedKeys?.insert(key)
                let store = clientStore
                let name = identity.name, path = identity.path, seenAt = now()
                _ = await Task.detached(priority: .utility) { try? store.approve(name: name, path: path, now: seenAt) }.value
                return true
            case .deny, .ask:
                // A presenter is only ever asked when the registry itself returned `.ask`, so an
                // `.ask` answer back would be a contract violation — treated the same as `.deny`
                // (fail closed) rather than looping or crashing.
                deniedThisSession.insert(key)
                return false
            }
        }
    }

    private func recordSighting(_ identity: MCPClientIdentity) async {
        let store = clientStore
        let name = identity.name, path = identity.path, seenAt = now()
        _ = await Task.detached(priority: .utility) { try? store.recordSighting(name: name, path: path, now: seenAt) }.value
    }

    private func ensureApprovedKeysLoaded() async {
        guard approvedKeys == nil else { return }
        let store = clientStore
        let rows = await Task.detached(priority: .utility) { (try? store.all()) ?? [] }.value
        approvedKeys = Set(rows.filter(\.approved).map { ClientRegistry.key(MCPClientIdentity(name: $0.name, path: $0.path, pid: nil)) })
    }

    // MARK: transcribe_file

    private func transcribeFile(_ arguments: JSONValue) async -> ToolOutcome {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
            return .toolFailure(.invalidParams, message: "path is required")
        }
        let url: URL
        do {
            url = try pathPolicy.check(path,
                fileExists: { FileManager.default.fileExists(atPath: $0.path) },
                isRegularFile: { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false })
        } catch let rejection as PathPolicy.Rejection {
            return .toolFailure(.invalidParams, message: rejection.message)
        } catch {
            return .toolFailure(.invalidParams, message: String(describing: error))
        }
        let format = OutputFormat(configValue: arguments["format"]?.stringValue ?? "text") ?? .txt
        do {
            let document = try await fileTranscribing.transcribe(url, options: TranscriptionOptions()) { _ in }
            return .success(TranscriptRenderer.render(document, format: format, timestamps: false))
        } catch {
            // Same convention `DictationController` uses for transcription failures.
            return .toolFailure(.internalError, message: String(describing: error))
        }
    }

    // MARK: dictate

    private func dictate() async -> ToolOutcome {
        guard !coordinator.isHUDActive else { return .toolFailure(.busy, message: MCPToolError.dictationAlreadyRunning) }
        guard coordinator.pausedUntil == nil else { return .toolFailure(.busy, message: MCPToolError.dictationPaused) }

        // Subscribe *before* starting the capture (`DictationController.results()`'s documented
        // contract) — the underlying `AsyncStream` is `.unbounded`, so a result yielded before this
        // function's own child task starts iterating it is buffered, not lost.
        let resultsStream = await controller.results()
        coordinator.startProgrammaticDictation()
        let config = await controller.config
        let timeout = config.maxDuration + config.processingTimeout

        // Race the first `results()` element against the timeout, on the injected clock. Whichever
        // child finishes first via `group.next()` wins; `group.cancelAll()` then cancels the loser —
        // the `for await` child's `next()` returns `nil` promptly on cancellation (firing
        // `onTermination`, so `results()`'s subscriber entry is removed, not leaked) and the sleeper
        // child's `clock.sleep` throws `CancellationError`, swallowed by `try?`. Either way
        // `withTaskGroup` awaits the cancelled child to finish before returning, so this never
        // leaves an orphaned subscriber or an orphaned sleeper behind.
        let outcome: DictationResult? = await withTaskGroup(of: DictationResult?.self) { group in
            group.addTask {
                for await result in resultsStream { return result }
                return nil
            }
            group.addTask { [clock] in
                try? await clock.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let outcome else { return .toolFailure(.timedOut, message: MCPToolError.dictationTimedOut) }
        return .success(outcome.text)
    }

    // MARK: search_history

    private static let defaultSearchLimit = 20
    private static let maxSearchLimit = 100

    private struct SearchHit: Encodable {
        var text: String
        var app: String?
        var createdAt: String
        var words: Int
    }

    /// Fixed `en_US_POSIX`/UTC so `createdAt` renders identically regardless of the host's locale
    /// or time zone (the tests' determinism requirement) — a classic ISO 8601 `…Z` timestamp.
    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()

    private func searchHistory(_ arguments: JSONValue) async -> ToolOutcome {
        // Forces the first open (or an in-flight reopen) to resolve, so `status` below reflects
        // reality rather than `HistoryService.notOpenedYetReason`'s startup placeholder.
        await historyService.ready()
        if case .disabled(let reason) = historyService.status {
            return .toolFailure(.historyUnavailable, message: HistoryViewModel.readableReason(reason))
        }
        let query = arguments["query"]?.stringValue ?? ""
        let requestedLimit = arguments["limit"]?.intValue ?? Self.defaultSearchLimit
        let limit = min(max(requestedLimit, 0), Self.maxSearchLimit)
        // Defense in depth: `DictationStore.search` already skips unreadable rows for a non-blank
        // query, but a blank query returns everything *including* unreadable rows — filtered again
        // here regardless, so an unreadable row never reaches an MCP client either way.
        let hits = await historyService.search(query)
            .filter { !$0.isUnreadable }
            .prefix(limit)
            .map { SearchHit(text: $0.text, app: $0.appName, createdAt: Self.historyDateFormatter.string(from: $0.createdAt), words: $0.words) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(hits), let json = String(data: data, encoding: .utf8) else {
            return .toolFailure(.internalError, message: "Failed to render search results")
        }
        return .success(json)
    }

    // MARK: wire helpers

    private enum ToolOutcome {
        case success(String)
        case failure(code: Int, message: String, httpStatus: Int)

        static func toolFailure(_ kind: MCPError, message: String) -> ToolOutcome {
            .failure(code: kind.code, message: message, httpStatus: kind.httpStatus)
        }
    }

    private static func textContent(_ text: String) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    private static func encode(_ response: JSONRPCResponse) -> Data? {
        try? JSONEncoder().encode(response)
    }
}
