# VoxFlow v2 Phase 6 — loopback MCP server — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver #113: a loopback-only MCP server inside VoxFlow that Cursor (and Claude Desktop through `mcp-remote`) can connect to with the token from Settings › MCP Server, exposing `transcribe_file`, `dictate` and `search_history`, with a per-client approval dialog (ST-06a), a connected-clients list with revoke, and a path policy that keeps `transcribe_file` away from anything the user did not mean to share.

**Architecture:** `VoxFlowMCP` (package) is pure protocol and policy — JSON-RPC codecs, a router that answers both the modern (`server/discover`, per-request `_meta`) and legacy (`initialize` handshake) protocol eras, tool descriptors, token comparison, `Origin`/header validation, `PathPolicy`, and `ClientRegistry` rules. It owns no sockets. The app owns `LoopbackListener` (`NWListener`, loopback-only, port 7331…7340), `PeerIdentity` (pid + process name via `libproc`), the three tool implementations over existing services, the ST-06a approval panel, and the Settings wiring. Everything the server does is one HTTP POST in, one JSON object out — no SSE, no sessions.

**Tech Stack:** Network.framework (`NWListener`/`NWConnection`), `libproc`, Swift 6 strict concurrency, `Synchronization.Mutex`, GRDB (new `mcp_clients` table), Swift Testing, SwiftUI/AppKit panel, XcodeGen.

**Spec:** design spec §1 ("expose both to local AI clients over MCP"), §2 (MCP on loopback with token, tools `transcribe_file`/`dictate`/`search_history`), §3 (`VoxFlowMCP/` = loopback HTTP MCP, token, client approval, path policy), §5 (`mcp_clients` table; access token in the Keychain), §7 Testing. Canvas: ST-06 Settings › MCP Server (PDF page 6), ST-06a client request (page 5), ST-06r regenerate (page 5), 3e "MCP port busy". Issue #113. Spike facts (protocol shapes, the working `NWListener` recipe, the three gotchas, `libproc` pid resolution, client config snippets): `docs/superpowers/plans/2026-09-10-phase6-mcp-spike-notes.md` — read it before Task 1; every value it reports was measured on this Mac, not guessed.

**Rulings (binding):**

1. **Two protocol eras, one router.** Advertise `supportedVersions: ["2026-07-28", "2025-06-18"]`. Modern requests carry `params._meta["io.modelcontextprotocol/protocolVersion"]`; legacy ones open with `initialize` and are recognised by its absence. `server/discover` and `initialize` both answer. Real clients today (Cursor, `mcp-remote`) speak the legacy era, so the legacy path is the one that must work end to end; the modern path is answered but only unit-tested.
2. **HTTP rules** (spec, verified in the spike): POST only on `/mcp`; `GET`/`DELETE` → `405`; invalid `Origin` (present and not `http://127.0.0.1[:port]` / `http://localhost[:port]`) → `403`; missing or wrong bearer token → `401`; unknown method → `404` with JSON-RPC `-32601`; unsupported protocol version → `400` with `UnsupportedProtocolVersionError`; a modern request whose `MCP-Protocol-Version` / `Mcp-Method` / `Mcp-Name` header disagrees with the body → `400` with `-32020`. `Mcp-Session-Id` and `Last-Event-ID` are ignored. Every answer is `Content-Type: application/json`, `Connection: close`. Legacy requests without headers are accepted (the spec's `MAY treat as 2025-03-26`).
3. **Loopback binding** — `NWParameters.tcp` with `requiredInterfaceType = .loopback`, then `NWListener(using:on:)`, scanning 7331…7340 for the first port that opens. Never `requiredLocalEndpoint` (spike gotcha 1: reports ready, binds nothing). Additionally drop any connection whose `remoteEndpoint` host is not `127.0.0.1`/`::1`. When the bound port is not 7331, ST-06 shows the real endpoint plus the note `Port 7331 was busy — update your client with the Copy button.` (canvas 3e).
4. **Token** — the existing `MCPSettings.token` (`vf_` + 32 hex, Keychain `dev.artemsem.voxflow` / `mcp-token`). Compared in constant time. `Regenerate` (ST-06r) rotates it and **drops every approved client**, because a client's identity is "held the old token".
5. **Client approval (ST-06a).** A first call from an unknown client suspends the request and shows a floating panel (non-activating, like MB-00, so it works with the main window closed): title `"{name}" wants to use VoxFlow`, body `A local app connected to the MCP server with a valid token. It can use: {enabled tools, comma-separated}.`, line `Process: {name} (pid {pid}) · 127.0.0.1`, buttons `Always allow` / `Allow once` / `Deny`. Identity = process name + pid resolved through `libproc`; when resolution fails the identity is `Unknown app` with no pid line, and the request is still gated by the same dialog. `Always allow` persists a row in `mcp_clients` (name, bundle-ish executable path, first seen, last seen); `Allow once` allows for that TCP connection only; `Deny` answers `-32001` and is remembered for the session. A request waiting on a decision times out after **60 s** with `-32001`. Approval is per process name + executable path, not per pid (a client that restarts keeps its approval).
6. **Tools.** Each is gated twice: the Settings toggle (`mcp.tool.*`) and client approval. A disabled tool is absent from `tools/list` and answers `-32601` on call.
   - `transcribe_file` — `{path: string, format?: "text" | "srt" (default "text")}`. Path goes through `PathPolicy` (ruling 7), then the existing `FileTranscribing.transcribe(_:options:progress:)` and `TranscriptRenderer`. Result is one `content: [{type:"text", text}]`.
   - `dictate` — `{}` (no arguments). Refuses with `-32002` when a dictation is already running or dictation is paused. Otherwise runs **one hands-free capture** through the same `DictationController` the hotkey uses (the Flow Bar shows it; the text is inserted and saved exactly as a normal dictation) and returns the final text. Times out after `FlowBarConfig.maxDuration + processingTimeout` and returns `-32003`.
   - `search_history` — `{query: string, limit?: int (default 20, max 100)}` over `HistoryService.search`. Off by default. Each hit renders as `{text, app, createdAt (ISO 8601), words}` in one JSON text block. Unreadable rows are skipped; history disabled → `-32004` with the reason.
7. **`PathPolicy`** — `transcribe_file` accepts a path only when, after resolving symlinks, it is a regular readable file, inside the user's home directory, **not** under `~/Library`, and carries one of the extensions the Files pipeline already supports. Everything else is `-32602` with the reason. No path is ever remembered; there is no "grant a folder" flow in the canvas, so there is none here.
8. **`mcp_clients` table** (spec §5) — migration `v3`: `id INTEGER PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL, approved INTEGER NOT NULL, first_seen DOUBLE NOT NULL, last_seen DOUBLE NOT NULL, UNIQUE(name, path)`. Not encrypted (no dictation content). `MCPClientStore` in `VoxFlowStorage` alongside the other stores; the connected-clients list and revoke read and write it.
9. **Server lifecycle** — the listener starts when `mcp.enabled` turns on (and at launch when it is already on, non-test only) and stops when it turns off. Turning it off drops in-flight connections. A bind failure across the whole range surfaces in ST-06 as `Couldn't start the server — ports 7331–7340 are all in use.` and the toggle snaps back off (the same pattern as Launch at login).
10. **No outbound network.** The server never opens a connection; the privacy footer keeps saying "0 bytes sent since install". A test asserts `VoxFlowMCP` contains no `URLSession`/`NWConnection(to:)` use.

## Global Constraints

- Swift 6 strict concurrency; view models `@Observable @MainActor`; no `@unchecked Sendable` / `nonisolated(unsafe)` / `assumeIsolated` — the connection handler is a `final class … : Sendable` whose only mutable state is a `Mutex` (spike gotcha 3).
- Views hold no rules; every number/string decision in a tested type. Copy verbatim from the canvas (quoted per task). Design reference `.superpowers/design/canvas.pdf`; render tests (`VOXFLOW_RENDER=1`) per UI task; implementer + reviewer compare.
- Blocking work off the main actor; no sleeps in non-render tests (`FakeClock`).
- Unit tests never open a socket. The one integration test that does is tagged and skips when it cannot bind.
- Commits: Conventional Commits, owner-authored, no attribution. Branch `feature/113-v2-mcp-server` from `develop`; PR into `develop`.
- Verification per task: `cd VoxFlowKit && swift test` where the package changed; `xcodegen generate && xcodebuild -scheme VoxFlow -destination 'platform=macOS' build test`.

---

### Task 1: `VoxFlowMCP` protocol core — JSON-RPC, router, tool descriptors, errors

**Files:**
- Create: `VoxFlowKit/Sources/VoxFlowMCP/JSONRPC.swift` — `JSONRPCRequest` (`id: JSONRPCID?`, `method`, `params: JSONValue?`), `JSONRPCID` (`.number(Int)` / `.string(String)`), `JSONValue` (a minimal `Codable` JSON tree: null/bool/number/string/array/object, with `subscript(String)` and typed accessors `stringValue`, `intValue`, `objectValue`), `JSONRPCError` (`code`, `message`, `data: JSONValue?`) and `JSONRPCResponse`.
- Create: `VoxFlowKit/Sources/VoxFlowMCP/MCPError.swift` — the code table as one enum: `.parse(-32700)`, `.invalidRequest(-32600)`, `.methodNotFound(-32601)`, `.invalidParams(-32602)`, `.internalError(-32603)`, `.headerMismatch(-32020)`, `.unauthorized(-32001)`, `.busy(-32002)`, `.timedOut(-32003)`, `.historyUnavailable(-32004)`, plus `httpStatus` (`methodNotFound` → 404, `headerMismatch`/`unsupportedVersion` → 400, `unauthorized` → 401, everything else → 200 with a JSON-RPC error body).
- Create: `VoxFlowKit/Sources/VoxFlowMCP/MCPProtocol.swift` — `MCPProtocolVersion` (`current = "2026-07-28"`, `legacy = "2025-06-18"`, `supported = [current, legacy]`), `ServerIdentity(name: "VoxFlow", version:)`, and the `_meta` key constants (`io.modelcontextprotocol/protocolVersion`, `…/clientInfo`, `…/serverInfo`).
- Create: `VoxFlowKit/Sources/VoxFlowMCP/MCPTool.swift` — `MCPToolID` (`transcribeFile`, `dictate`, `searchHistory`) with `name` (`"transcribe_file"`, `"dictate"`, `"search_history"`) and `descriptor` carrying the canvas description and the `inputSchema` from ruling 6. Descriptions verbatim: `"Transcribe an audio file at a path; returns text or SRT"`, `"Start a dictation and return the cleaned-up text"`, `"Search past dictations — off by default"`.
- Create: `VoxFlowKit/Sources/VoxFlowMCP/MCPRouter.swift`:

```swift
public struct MCPRequestContext: Sendable, Equatable {
    public var enabledTools: Set<MCPToolID>
    public var serverVersion: String
    public init(enabledTools: Set<MCPToolID>, serverVersion: String)
}

/// What the transport must do with a routed request. `callTool` is the only case that needs the app.
public enum MCPRouted: Sendable, Equatable {
    case result(JSONValue)                       // answer verbatim
    case accepted                                // 202, no body (a notification)
    case callTool(MCPToolID, arguments: JSONValue, id: JSONRPCID?)
    case failure(MCPError, id: JSONRPCID?)
}

public struct MCPRouter: Sendable {
    public init() {}
    public func route(_ request: JSONRPCRequest, context: MCPRequestContext) -> MCPRouted
}
```

  Handled methods: `server/discover` (modern result per the spike notes, `resultType: "complete"`, `supportedVersions`, `capabilities: {"tools": {}}`, `_meta` serverInfo), `initialize` (legacy result: `protocolVersion` echoing the client's when supported else `legacy`, `capabilities: {"tools": {}}`, `serverInfo`), `notifications/initialized` → `.accepted`, `tools/list` (only enabled tools), `tools/call` → `.callTool` when the named tool is enabled, `.failure(.methodNotFound)` otherwise; anything else `.failure(.methodNotFound)`.
- Create: `VoxFlowKit/Sources/VoxFlowMCP/MCPHTTPPolicy.swift` — pure validation the transport applies before routing:

```swift
public struct MCPHTTPRequest: Sendable, Equatable {
    public var method: String            // "POST"
    public var path: String
    public var headers: [String: String] // lowercased keys
    public var body: Data
}

public enum MCPHTTPVerdict: Sendable, Equatable {
    case proceed(JSONRPCRequest)
    case status(Int, JSONRPCError?)      // 401/403/405/400 with an optional JSON-RPC body
}

public struct MCPHTTPPolicy: Sendable {
    public init(endpointPath: String = "/mcp")
    /// `token` is compared in constant time; `boundPort` is used to accept `http://127.0.0.1:<port>` origins.
    public func verdict(for request: MCPHTTPRequest, token: String, boundPort: UInt16) -> MCPHTTPVerdict
}
```

  Order: path mismatch → 404; `GET`/`DELETE` → 405; other non-POST → 405; bad `Origin` → 403; bad/missing bearer → 401; unparseable body → 400 with `-32700`; modern request (body has the `_meta` version) whose headers disagree → 400 with `-32020`; unsupported version → 400 with `UnsupportedProtocolVersionError` (`data.supported = supportedVersions`).
- Create: `VoxFlowKit/Sources/VoxFlowMCP/ConstantTimeCompare.swift` — `public func constantTimeEquals(_ a: String, _ b: String) -> Bool` (compare UTF-8 bytes, always the full length of the longer input).
- Delete: `VoxFlowKit/Sources/VoxFlowMCP/MCPModule.swift` (the stub) and its test, after moving `coreVersion` use — check `grep -rn "MCPModule" --include=*.swift .` first and update every call site.
- Test: `VoxFlowKit/Tests/VoxFlowMCPTests/{JSONValueTests,MCPRouterTests,MCPHTTPPolicyTests,MCPToolTests}.swift`.

**Interfaces:**
- Produces: everything above; Task 2 consumes `MCPHTTPPolicy`, `MCPRouter`, `MCPRouted`, `MCPError`; Task 3 consumes `MCPToolID` and `JSONValue`.

**Test cases (write first, watch them fail):**
1. `JSONValue` round-trips a nested object through `JSONEncoder`/`JSONDecoder` and preserves integer-vs-double.
2. `server/discover` result lists both versions, `capabilities.tools` is present, `serverInfo.name == "VoxFlow"`.
3. `initialize` with `protocolVersion: "2025-06-18"` echoes it; with `"1999-01-01"` the router still answers legacy (version rejection is the policy's job, not the router's).
4. `tools/list` with only `transcribeFile` enabled returns exactly one descriptor, name `transcribe_file`, description verbatim, `inputSchema.required == ["path"]`.
5. `tools/call` for a disabled tool → `.failure(.methodNotFound)`; for an enabled one → `.callTool` with the arguments passed through.
6. `notifications/initialized` → `.accepted`.
7. Policy: `GET /mcp` → 405; `POST /nope` → 404; `Origin: https://evil.example` → 403; `Origin: http://127.0.0.1:7333` with `boundPort: 7333` → proceeds; missing `Authorization` → 401; `Bearer wrong` → 401; correct token → proceeds.
8. Policy: a modern body (`_meta` version `2026-07-28`) with header `MCP-Protocol-Version: 2025-06-18` → 400 `-32020`; the same body with a matching header and `Mcp-Method: tools/list` → proceeds; a `tools/call` body whose `Mcp-Name` header disagrees with `params.name` → 400 `-32020`.
9. Policy: `_meta` version `1999-01-01` → 400 with `UnsupportedProtocolVersionError` naming both supported versions.
10. Policy: a legacy body with no `_meta` and no MCP headers → proceeds.
11. `constantTimeEquals` is true only for equal strings and false for a prefix (`"vf_a"` vs `"vf_ab"`).

- [ ] Tests → RED → implementation → GREEN (`cd VoxFlowKit && swift test --filter VoxFlowMCPTests`, then the full package suite).
- [ ] Commit: `feat(mcp): JSON-RPC core, router for both protocol eras, HTTP policy and tool descriptors`

### Task 2: Loopback transport, peer identity, client registry, path policy

**Files:**
- Create: `VoxFlowKit/Sources/VoxFlowMCP/PathPolicy.swift` (ruling 7):

```swift
public struct PathPolicy: Sendable {
    public enum Rejection: Error, Equatable, Sendable {
        case notAbsolute, notFound, notRegularFile, outsideHome, insideLibrary, unsupportedType(String)
        public var message: String { … }   // exact, tested
    }
    public init(homeDirectory: URL, allowedExtensions: Set<String>)
    /// Resolves symlinks first, so `~/Desktop/link-to-/etc/passwd` is judged by its target.
    public func check(_ path: String, fileExists: (URL) -> Bool, isRegularFile: (URL) -> Bool) throws -> URL
}
```

- Create: `VoxFlowKit/Sources/VoxFlowMCP/ClientRegistry.swift` — pure decision rules over injected state:

```swift
public struct MCPClientIdentity: Sendable, Hashable {
    public var name: String       // "Cursor", or "Unknown app"
    public var path: String       // executable path, "" when unresolved
    public var pid: Int32?
}

public enum MCPClientDecision: Sendable, Equatable { case allow, deny, ask }

public struct ClientRegistry: Sendable {
    public init()
    public func decision(for identity: MCPClientIdentity, approved: Set<String>, deniedThisSession: Set<String>, allowedOnce: Set<String>) -> MCPClientDecision
    /// The key both the registry and `mcp_clients` use — name + path, never the pid (ruling 5).
    public static func key(_ identity: MCPClientIdentity) -> String
}
```

- Create: `VoxFlowKit/Sources/VoxFlowStorage/MCPClientStore.swift` + migration `v3` (ruling 8) in `VoxFlowDatabase.swift`: `insertOrTouch(name:path:approved:now:)`, `all() -> [MCPClientRecord]`, `revoke(id:)`, `revokeAll()`. Follow `DictionaryStore` for shape and `StorageError.duplicate` handling.
- Create: `VoxFlow/MCP/PeerIdentity.swift` (app) — `libproc` resolution exactly as the spike verified (`proc_listallpids` → `PROC_PIDLISTFDS` → `PROC_PIDFDSOCKETINFO`, match `insi_lport` big-endian to the peer port, `proc_name`). Signature `func resolveProcess(peerPort: UInt16, serverPort: UInt16) -> (pid: Int32, name: String, path: String)?` (amended in the Task 2 review: matching the client's local port alone can mis-attribute a connection to an innocent process, so the socket must match **both** ends and be established), using `proc_pidpath` for the path. Behind a protocol `PeerResolving` so tests inject a fake.
- Create: `VoxFlow/MCP/LoopbackListener.swift` (app) — `NWListener` per ruling 3 and the recipe in the spike notes; `final class ConnectionHandler: Sendable` with a `Mutex<Data>` buffer (spike gotcha 3); HTTP framing (headers to `\r\n\r\n`, then `Content-Length` bytes); replies `Connection: close`. API:

```swift
protocol MCPRequestHandling: Sendable {
    func handle(_ request: MCPHTTPRequest, peer: MCPClientIdentity) async -> (status: Int, body: Data?)
}

actor LoopbackListener {
    init(portRange: ClosedRange<UInt16> = 7331...7340, resolver: any PeerResolving, handler: any MCPRequestHandling)
    private(set) var boundPort: UInt16?
    func start() throws            // throws MCPServerError.noFreePort
    func stop()
}
```

- Create: `VoxFlow/MCP/HTTPMessage.swift` (app) — the request parser and response writer, pure and unit-tested (no socket).
- Test: `VoxFlowKit/Tests/VoxFlowMCPTests/{PathPolicyTests,ClientRegistryTests}.swift`, `VoxFlowKit/Tests/VoxFlowStorageTests/MCPClientStoreTests.swift`, `VoxFlowTests/HTTPMessageTests.swift`.

**Interfaces:**
- Consumes: `MCPHTTPRequest`, `MCPClientIdentity` (Task 1 / this task).
- Produces: `LoopbackListener`, `PeerResolving`, `MCPRequestHandling`, `PathPolicy`, `ClientRegistry`, `MCPClientStore`.

**Test cases:**
1. `PathPolicy`: a file under `~/Music/a.wav` with `wav` allowed passes and returns the resolved URL; `/etc/passwd` → `.outsideHome`; `~/Library/x.wav` → `.insideLibrary`; `~/Desktop/notes.txt` → `.unsupportedType("txt")`; a relative path → `.notAbsolute`; a symlink in the home pointing at `/etc/passwd` → `.outsideHome` (proves resolution happens first); every `Rejection.message` is asserted verbatim.
2. `ClientRegistry`: unknown → `.ask`; approved key → `.allow`; denied-this-session → `.deny`; allowed-once → `.allow`; the key ignores the pid (same name+path with different pids share a decision).
3. `MCPClientStore`: insert then `all()` returns it; a second `insertOrTouch` with the same name+path updates `last_seen` without a duplicate row; `revoke` removes it; the `v3` migration runs on a database created at `v2`.
4. `HTTPMessage`: a request split across three chunks parses only once complete; `Content-Length` shorter than the body truncates; a request with no body and no `Content-Length` parses; header names are lowercased; a response renders the exact status line, `Content-Type`, `Content-Length` and `Connection: close`.
5. `LoopbackListener` is exercised only by the Task 5 integration test; here assert `MCPServerError.noFreePort` copy.

- [ ] Tests → RED → implementation → GREEN.
- [ ] Commit: `feat(mcp): loopback listener, peer identity, client registry, path policy and the mcp_clients table`

### Task 3: The three tools and the `dictate` seam

**Files:**
- Modify: `VoxFlowKit/Sources/VoxFlowDictation/DictationController.swift` — add a broadcast of finished results so a programmatic caller can await one:

```swift
/// Every completed capture's result, in order. Fed where `onSave` is invoked, so an MCP `dictate`
/// call observes exactly what a hotkey dictation produced — including one that was only copied.
public func results() -> AsyncStream<DictationResult>
```

  Implement with the same multi-subscriber pattern `currentAndChanges()` already uses; a subscriber that arrives after a result misses it (the caller subscribes before starting the capture).
- Create: `VoxFlow/MCP/MCPToolRunner.swift` (app) — `MCPRequestHandling` implementation that ties everything together: policy → router → approval → tool. Holds `MCPSettings`, `ClientRegistry` state, `MCPClientStore`, the approval presenter, and the three tool closures. Tool bodies:
  - `transcribeFile`: `PathPolicy.check` → `FileTranscribing.transcribe(url, options:progress:)` → `TranscriptRenderer.render(document, format: .txt/.srt, timestamps:)`; errors map to `-32602` (bad path) or `-32603` (engine) with the underlying message.
  - `dictate`: guard `!coordinator.isHUDActive` and `coordinator.pausedUntil == nil` else `-32002` (`"A dictation is already running."` / `"Dictation is paused."`); subscribe to `controller.results()`; `coordinator.startProgrammaticDictation()`; await the first result or the timeout (`-32003`, `"Dictation timed out."`).
  - `searchHistory`: `HistoryService.status` must be `.enabled` else `-32004` with `HistoryViewModel.readableReason`; `history.search(query)`, drop `isUnreadable`, take `limit`, render `[{text, app, createdAt, words}]` as pretty JSON in one text block.
- Modify: `VoxFlow/Dictation/DictationCoordinator.swift` — `func startProgrammaticDictation()` that yields the same hands-free start the hotkey uses (`commands.yield(.fn(.down))` with the hands-free path), documented as the MCP seam; it must not bypass preflight, the HUD, or insertion.
- Create: `VoxFlow/MCP/MCPToolError.swift` — the user-facing message table, tested verbatim.
- Test: `VoxFlowKit/Tests/VoxFlowDictationTests/DictationControllerTests.swift` (+ `results()` cases), `VoxFlowTests/MCPToolRunnerTests.swift` with fakes for every dependency.

**Interfaces:**
- Consumes: `MCPRouter`, `MCPHTTPPolicy`, `PathPolicy`, `ClientRegistry`, `MCPClientStore` (Tasks 1–2); `FileTranscribing`, `HistoryService`, `DictationCoordinator` (existing).
- Produces: `MCPToolRunner` (an `MCPRequestHandling`), `DictationController.results()`, `DictationCoordinator.startProgrammaticDictation()`.

**Test cases:**
1. `results()` yields one element per completed capture, in order, to two concurrent subscribers.
2. `transcribe_file` with an allowed path returns the rendered text; with `format: "srt"` returns SRT (assert a `-->` timecode line); with `/etc/passwd` returns `-32602` and the exact `PathPolicy` message; a transcription failure returns `-32603` carrying the engine message.
3. `dictate` while `isHUDActive` → `-32002` with the exact copy; while paused → `-32002` with the paused copy; on the happy path it starts a capture and returns the result's `text`; when no result arrives before the timeout → `-32003` (drive with `FakeClock`).
4. `search_history` with history disabled → `-32004` and the readable reason; enabled → hits rendered with `text`/`app`/`createdAt`/`words`, `limit` respected, unreadable rows skipped, `limit: 500` clamped to 100.
5. A disabled tool called by name → `-32601` (the runner re-checks, not only `tools/list`).
6. An unapproved client calling any tool asks the presenter exactly once and, on `Always allow`, writes one `mcp_clients` row; on `Deny` answers `-32001` and does not ask again in the same session.

- [ ] Tests → RED → implementation → GREEN.
- [ ] Commit: `feat(mcp): transcribe_file, dictate and search_history over the existing pipelines`

### Task 4: Settings › MCP Server for real, ST-06a approval panel, connected clients

**Design (PDF page 6 ST-06, page 5 ST-06a/ST-06r):** the page keeps its phase-4b layout; the footnote `Server arrives in a later release.` is removed. The endpoint row shows the **bound** endpoint and, when the port is not 7331, the note `Port 7331 was busy — update your client with the Copy button.` Connected clients replaces the empty state with one row per `mcp_clients` record: name, `Last used {relative}`, and a `Revoke` button; the empty text stays `No clients yet — connect Claude Desktop or Cursor with the token above.` ST-06a is a floating panel, not a sheet (it must appear with the main window closed): title `"{name}" wants to use VoxFlow`, body `A local app connected to the MCP server with a valid token. It can use: {tools}.`, line `Process: {name} (pid {pid}) · 127.0.0.1`, buttons `Always allow`, `Allow once`, `Deny`.

**Files:**
- Modify: `VoxFlow/Settings/MCPViewModel.swift` — `boundEndpoint`, `portNote`, `clients: [MCPClientRow]`, `startFailure: String?`, `revoke(_:)`, `refreshClients()`; `enabled` now drives `MCPServerService.start()/stop()` and snaps back with `startFailure` on `noFreePort` (copy: `Couldn't start the server — ports 7331–7340 are all in use.`). `Regenerate` also revokes every client (ruling 4) and the alert message gains that sentence: `Claude Desktop and Cursor will be disconnected until you paste the new token into them. Approved clients are cleared.`
- Modify: `VoxFlow/Settings/MCPSettingsView.swift` — bound endpoint + note, clients list with `Revoke`, start-failure line; remove the "later release" footnote.
- Create: `VoxFlow/MCP/MCPApprovalPanel.swift` + `MCPApprovalViewModel.swift` — the ST-06a panel (reuse `MenuBarHintPanel`'s non-activating `NSPanel` shape); `present(identity:tools:) async -> MCPClientDecision` with a 60 s timeout (ruling 5) returning `.deny`.
- Create: `VoxFlow/MCP/MCPServerService.swift` — owns `LoopbackListener` + `MCPToolRunner`, exposes `start()`/`stop()`/`boundPort`, started at launch when enabled (non-test, `LaunchEnvironment.isRunningTests` gated) from `AppDelegate`.
- Modify: `VoxFlow/App/AppServices.swift`, `VoxFlow/App/AppDelegate.swift` — build and wire the service; `Navigation` gains nothing new.
- Test: `VoxFlowTests/MCPViewModelTests.swift` (bound endpoint, port note, start failure snap-back, revoke, regenerate clears clients), `VoxFlowTests/MCPApprovalViewModelTests.swift` (copy verbatim, timeout → deny, each button's decision), `VoxFlowTests/MCPRenderTests.swift` (`VOXFLOW_RENDER=1` → `.superpowers/design/renders/MCP-settings.png`, `MCP-approval.png`; compare with pages 6 and 5).

- [ ] Tests → RED → implementation → GREEN; render and compare with the canvas.
- [ ] Commit: `feat(app): Settings › MCP Server backed by the real server, ST-06a approval, connected clients`

### Task 5: Integration test, ADR-008, docs, owner checklist

**Files:**
- Create: `VoxFlowTests/MCPServerIntegrationTests.swift` — starts a real `LoopbackListener` on the range, then over loopback HTTP: `initialize` → `tools/list` → `tools/call transcribe_file` on a fixture WAV (reusing the `RequiresModel` fixture and skipping with a printed reason when no speech model is installed) → `tools/call search_history` against a seeded temporary store. `dictate` is **not** exercised (it needs a microphone); assert instead that it answers `-32002` while a fake capture is active. Also assert: no bearer → 401, `GET` → 405, foreign `Origin` → 403. Skips with a printed reason when no port in 7331…7340 can be bound.
- Create: `docs/adr/008-loopback-mcp-server.md` — Context (spec §2/§3, canvas ST-06/06a, #113), Decision (rulings 1–10 in prose, including the two protocol eras, the `NWListener` recipe and why not `requiredLocalEndpoint`, `libproc` identity and its sandbox dependency, approval keyed on name+path, the path policy, no SSE/sessions), Consequences (a sandboxed build would lose the process line in ST-06a; `transcribe_file` competes with dictation for the single whisper queue — #145; `mcp-remote` is required for Claude Desktop until it supports custom headers; the token in the Keychain is the only credential, so regenerating disconnects everyone). Add the row to `docs/adr/README.md`.
- Create: `docs/runbooks/connect-an-mcp-client.md` — the two client snippets from the spike notes (Cursor direct, Claude Desktop via `mcp-remote`), where the token lives, what the approval dialog looks like, how to revoke, and what to do when the port moved.
- Modify: `README.md` (feature list), `CHANGELOG.md` (Unreleased), `SETUP.md` (a "MCP server" paragraph pointing at the runbook).
- Append to this plan: `## Manual checklist (owner)` — enable the server in Settings › MCP Server; copy the token; connect Cursor with the snippet; approve it in the ST-06a dialog with the main window closed; run each of `transcribe_file` (on a real audio file), `dictate` (speak, watch the Flow Bar, see the text returned) and `search_history` (after turning it on); revoke the client and confirm the next call fails; regenerate the token and confirm the client is disconnected and the list is empty; occupy 7331 (`nc -l 7331`) and confirm the endpoint moves with the note.

- [ ] Tests → RED → implementation → GREEN; full verification; commit `test(mcp): loopback integration test` and `docs: ADR-008 loopback MCP server, client runbook, phase 6 checklist`

---

## Manual checklist (owner)

Filled in by Task 5.

## Self-review

- **Spec coverage:** #113 criteria — unit tests for token/approval/path policy with fakes and no listener (Tasks 1–2); an integration test over the real loopback server calling the tools (Task 5, with `dictate` reasoned about rather than driven, disclosed); `swift test` green for `VoxFlowMCP` (Tasks 1–2); a real client connecting after approval (owner checklist, Task 5 runbook); revoke blocks the next call (Task 4 tests + checklist); CI green (PR). Spec §5's `mcp_clients` — Task 2 migration `v3`. Spec §2 "never makes an outbound network call" — ruling 10's test.
- **Placeholders:** none; every status code, error code, path rule and string is literal.
- **Type consistency:** `MCPHTTPRequest`/`MCPHTTPVerdict` (T1) consumed by `LoopbackListener` (T2) and `MCPToolRunner` (T3); `MCPRouted.callTool` (T1) is what `MCPToolRunner` switches on (T3); `MCPClientIdentity` (T2) flows listener → runner → approval panel (T4); `MCPToolID` (T1) keys the Settings toggles (T4); `DictationController.results()` (T3) is consumed only by the `dictate` tool.
