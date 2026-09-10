import Foundation
import VoxFlowCore
import VoxFlowDictation
import VoxFlowFiles
import VoxFlowMCP
import VoxFlowStorage

/// ST-06a: the client-approval dialog seam. `MCPToolRunner` asks this at most once per unapproved
/// client at a time (concurrent first calls for the same client await the same in-flight answer —
/// see `authorize`); Task 4 implements the real SwiftUI panel, tests use a fake. `tools` are the
/// wire names of every tool enabled right now (for the dialog's "wants access to: …" copy), not
/// just the one tool that triggered the prompt.
///
/// `canPersist` is `false` only when `identity.path` is empty (peer resolution didn't fully
/// resolve) — review finding I7/item 8: every unresolvable peer displays as the same `"Unknown
/// app"` identity, so persisting an approval for one would silently approve *all* of them. The
/// presenter must not offer "Always allow" when this is `false`; `MCPToolRunner` refuses to call
/// `MCPClientStore.approve` for such an identity regardless of what the presenter answers, falling
/// back to a session-scoped allow (see `.allowOnce`) if it answers `.allow` anyway.
protocol MCPApprovalPresenting: Sendable {
    func present(identity: MCPClientIdentity, tools: [String], canPersist: Bool) async -> MCPClientDecision
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

    /// Session-only: a "Deny" answer never writes to `mcp_clients` (persistence is opt-in via
    /// "Always allow", never opt-out) but must still stop the presenter being asked again this
    /// session — `ClientRegistry.decision` checks this before the (read-through, see `isApproved`)
    /// persisted set.
    private var deniedThisSession: Set<String> = []
    /// Session-only "Allow once" grants (review item 4 / plan ruling 5, amended): the seam sees a
    /// client identity, not a TCP connection, so `Allow once` is scoped to the rest of this runner's
    /// lifetime (the app session) and is never written to `mcp_clients`. Also where an `.allow`
    /// answer for an identity with no persistable path (`canPersist == false`, review item 8) lands.
    private var sessionAllowed: Set<String> = []
    /// One in-flight `approvalPresenter.present` call per client key (review item 3): a second
    /// concurrent call for the same unapproved client awaits this task's result instead of opening
    /// a second dialog. Set and read only inside `authorize`/`presentationDecision`, both of which
    /// run to completion (no `await`) between checking and inserting — see `presentationDecision`'s
    /// doc for why that makes the check-then-insert atomic on this actor.
    private var pendingPresentations: [String: Task<MCPClientDecision, Never>] = [:]

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

    func handle(_ request: MCPHTTPRequest, peer: MCPPeer) async -> (status: Int, body: Data?) {
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

    /// Final review F3: regenerating the token is the user saying "disconnect everyone". Persistent
    /// approvals are deleted from `mcp_clients`, but session-scoped grants ("Allow once") and
    /// session denials live only here, so without this a client that had been allowed once was
    /// silently re-admitted with no dialog — contradicting ruling 4, the ST-06r copy and the
    /// runbook. Clearing denials too is deliberate: the next call asks again, which is the safe
    /// direction and matches "everything about this session is reset".
    func clearSessionDecisions() {
        sessionAllowed.removeAll()
        deniedThisSession.removeAll()
    }

    private func handleToolCall(_ toolID: MCPToolID, arguments: JSONValue, id: JSONRPCID?, peer: MCPPeer) async -> (status: Int, body: Data?) {
        // The transport hands an empty `name` when peer resolution fails entirely — this is the one
        // place that substitutes the display copy (Task 2's resolution note); everything downstream
        // (the registry key, the approval dialog, the `mcp_clients` row) sees "Unknown app".
        // Final review F1: this is the first and only place the peer is actually resolved — the
        // request's token has already been checked by the policy above, so the ~5 ms process walk
        // is now something only an authenticated caller can trigger.
        // Re-review: `MCPToolRunner` is `@MainActor`, and the walk is a blocking ~5 ms / ~14,000
        // syscalls — the transport's own ruling is "never on `.main`". Hop off, same as the store
        // read below.
        let resolved = await Task.detached(priority: .userInitiated) { peer.identity() }.value
        let identity = resolved.name.isEmpty ? MCPClientIdentity(name: "Unknown app", path: resolved.path, pid: resolved.pid) : resolved
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
    /// approved ones — and `touchLastSeen` only ever updates an approved client's timestamp, so this can't silently
    /// de-approve/re-approve anyone; see `MCPClientStore`'s doc), then resolves through
    /// `ClientRegistry.decision` over `sessionAllowed`/`deniedThisSession` and a *read-through*
    /// query of `mcp_clients` (review item 2 — no cache, so Revoke/Regenerate take effect on the
    /// very next call, not only after a relaunch) and, only on `.ask`, calls the presenter through
    /// `presentationDecision`, which de-duplicates concurrent callers (review item 3).
    private func authorize(_ identity: MCPClientIdentity, toolNames: [String]) async -> Bool {
        let key = ClientRegistry.key(identity)
        // Review item 8: never persist an approval for an identity whose peer resolution didn't
        // fully resolve (empty `path`) — every such peer displays as the same "Unknown app" and
        // would otherwise all share one approval.
        let canPersist = !identity.path.isEmpty
        await touchLastSeen(identity)
        // `ClientRegistry.decision` takes the full `approved` set (Task 2's pure-function shape);
        // the read-through check below only ever needs to know about `key`, so it's wrapped as a
        // single-element set rather than fetching every approved key just to discard the rest.
        let approvedNow: Set<String> = await isApproved(key) ? [key] : []
        switch clientRegistry.decision(for: identity, approved: approvedNow, deniedThisSession: deniedThisSession, allowedOnce: sessionAllowed) {
        case .allow:
            return true
        case .allowOnce:
            // `ClientRegistry.decision` never itself returns this (it only reads persisted/session
            // state) — unreachable, kept only for exhaustiveness against `MCPClientDecision`.
            return true
        case .deny:
            return false
        case .ask:
            switch await presentationDecision(for: identity, toolNames: toolNames, canPersist: canPersist) {
            case .allow:
                if canPersist {
                    let store = clientStore
                    let name = identity.name, path = identity.path, seenAt = now()
                    _ = await Task.detached(priority: .utility) { try? store.approve(name: name, path: path, now: seenAt) }.value
                } else {
                    // The presenter shouldn't offer "Always allow" when `canPersist` is false, but
                    // if it answers `.allow` anyway, degrade to a session-scoped grant rather than
                    // either persisting a collapsible key or denying a client the presenter just
                    // approved.
                    sessionAllowed.insert(key)
                }
                return true
            case .allowOnce:
                sessionAllowed.insert(key)
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

    /// Runs `approvalPresenter.present` at most once per `identity`'s key at any given time: the
    /// `if let existing … return` check and the `pendingPresentations[key] = task` write below it
    /// are separated by no `await`, so — this method being `@MainActor`-isolated like the rest of
    /// this class — no other call can observe the key as "not pending" in between; a second
    /// concurrent call for the same key always finds the first's task already registered and awaits
    /// its `.value` instead of presenting again (review item 3).
    private func presentationDecision(for identity: MCPClientIdentity, toolNames: [String], canPersist: Bool) async -> MCPClientDecision {
        let key = ClientRegistry.key(identity)
        if let existing = pendingPresentations[key] { return await existing.value }
        let presenter = approvalPresenter
        let task = Task<MCPClientDecision, Never> { await presenter.present(identity: identity, tools: toolNames, canPersist: canPersist) }
        pendingPresentations[key] = task
        let decision = await task.value
        pendingPresentations[key] = nil
        return decision
    }

    private func touchLastSeen(_ identity: MCPClientIdentity) async {
        let store = clientStore
        let name = identity.name, path = identity.path, seenAt = now()
        _ = await Task.detached(priority: .utility) { try? store.touchLastSeen(name: name, path: path, now: seenAt) }.value
    }

    /// Read-through: no cache, so a Revoke or a token Regenerate (which drops every approved row)
    /// takes effect on the very next `authorize` call, not only after this runner is rebuilt
    /// (review item 2). `mcp_clients` is a handful of rows; reading it every approval decision is
    /// cheap and — like every other `MCPClientStore` access here — runs off this actor via
    /// `Task.detached`.
    private func isApproved(_ key: String) async -> Bool {
        let store = clientStore
        let rows = await Task.detached(priority: .utility) { (try? store.all()) ?? [] }.value
        return rows.contains { $0.approved && ClientRegistry.key(MCPClientIdentity(name: $0.name, path: $0.path, pid: nil)) == key }
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

    /// Authoritative in-runner busy gate (review item 1/C1): `coordinator.isHUDActive` is derived
    /// from `DictationCoordinator`'s state *mirror*, which only updates several actor-hops after
    /// `startProgrammaticDictation()` enqueues its commands — two concurrent `dictate` calls can
    /// both read `isHUDActive == false` and both pass. This flag is set synchronously, before this
    /// method's first `await`, and cleared in a `defer`, so — this class being `@MainActor` and
    /// this prefix containing no suspension point — a second call arriving while the first is still
    /// in flight always observes it `true` and is refused deterministically; there is no window
    /// where both can pass. `coordinator.isHUDActive`/`pausedUntil` stay as a secondary guard: they
    /// still catch a dictation the user started with the hotkey, which this flag knows nothing about.
    private var dictateInFlight = false

    private func dictate() async -> ToolOutcome {
        guard !coordinator.isHUDActive else { return .toolFailure(.busy, message: MCPToolError.dictationAlreadyRunning) }
        guard coordinator.pausedUntil == nil else { return .toolFailure(.busy, message: MCPToolError.dictationPaused) }
        guard !dictateInFlight else { return .toolFailure(.busy, message: MCPToolError.dictationAlreadyRunning) }
        dictateInFlight = true
        defer { dictateInFlight = false }

        // Subscribe *before* starting the capture (`DictationController.results()`'s documented
        // contract) — the underlying `AsyncStream` is `.unbounded`, so a result yielded before this
        // function's own child task starts iterating it is buffered, not lost. Same for `states()`
        // (review item 6's fast-failure race, below) — both subscriptions are registered, still
        // synchronously ahead of `dictateInFlight`'s own suspension-free prefix, before anything
        // starts.
        let resultsStream = await controller.results()
        let statesStream = await controller.states()
        coordinator.startProgrammaticDictation()
        let config = await controller.config
        // Each tool owns its own timeout budget; the transport's connection watchdog is only a
        // last-resort guard against a permanently pinned connection (order of 20 minutes), not a
        // per-request timeout — it does not need to, and must not, be shorter than this.
        let timeout = config.maxDuration + config.processingTimeout

        // Three-way race, on the injected clock: the first `results()` element, the capture
        // reaching a terminal state with no result (review item 6 — Escape, a transcription
        // failure, an empty transcript, no microphone, an excluded app, no model installed), or the
        // timeout. Whichever child finishes first via `group.next()` wins; `group.cancelAll()` then
        // cancels the other two — a cancelled `for await` child's `next()` returns `nil` promptly
        // (firing `onTermination`, so the `results()`/`states()` subscriber entries are removed, not
        // leaked) and a cancelled `clock.sleep` throws `CancellationError`, swallowed by `try?`.
        // `withTaskGroup` awaits every child before returning, so this never leaves an orphaned
        // subscriber or sleeper behind.
        let outcome: DictateRaceOutcome = await withTaskGroup(of: DictateRaceOutcome.self) { group in
            group.addTask {
                for await result in resultsStream { return .result(result) }
                return .timedOut
            }
            group.addTask {
                for await state in statesStream {
                    if let reason = MCPToolError.dictationFailureReason(for: state) { return .failed(reason) }
                }
                return .timedOut
            }
            group.addTask { [clock] in
                try? await clock.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        switch outcome {
        case .result(let result): return .success(result.text)
        case .failed(let reason): return .toolFailure(.captureFailed, message: reason)
        case .timedOut: return .toolFailure(.timedOut, message: MCPToolError.dictationTimedOut)
        }
    }

    private enum DictateRaceOutcome {
        case result(DictationResult)
        case failed(String)
        case timedOut
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
