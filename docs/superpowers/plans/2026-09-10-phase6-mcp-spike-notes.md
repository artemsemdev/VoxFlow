# Phase 6 MCP spike — verified facts (2026-09-10)

Probe package: `scratchpad/mcp-spike/probe` (throwaway, builds clean under `-strict-concurrency=complete`, zero warnings).

## 1. Protocol

Current revision is **`2026-07-28`** (modelcontextprotocol.io/specification/versioning). It changed the shape:

- Version is negotiated **per request** via `params._meta["io.modelcontextprotocol/protocolVersion"]`, mirrored in the `MCP-Protocol-Version` header. Mismatch → `400` + `HeaderMismatch` (`-32020`).
- **`server/discover`** is mandatory: result `{resultType, supportedVersions, capabilities, _meta["io.modelcontextprotocol/serverInfo"], instructions?, ttlMs?, cacheScope?}`.
- Streamable HTTP: **POST only**. GET/DELETE → `405`. No sessions (`Mcp-Session-Id` ignored), no `Last-Event-ID`, no GET SSE stream.
- Required headers on every POST: `MCP-Protocol-Version`, `Mcp-Method`, and `Mcp-Name` for `tools/call` / `resources/read` / `prompts/get`. Values must match the body; non-ASCII uses `=?base64?…?=`.
- Unknown method → `404` + JSON-RPC `-32601`. Unsupported version → `400` + `UnsupportedProtocolVersionError` listing supported versions.
- Security (MUST/SHOULD): validate `Origin` (invalid → `403`), bind only to 127.0.0.1, authenticate.

Legacy era (`2025-03-26` … `2025-11-25`): `initialize` handshake → `notifications/initialized` → `tools/list` / `tools/call`; optional `Mcp-Session-Id`; GET opens an SSE stream. **Real clients today speak this era**, so the server must answer both.

## 2. Clients

**Cursor** — `~/.cursor/mcp.json` (or `.cursor/mcp.json` per project), direct HTTP with headers:

```json
{"mcpServers":{"voxflow":{"url":"http://127.0.0.1:7331/mcp","headers":{"Authorization":"Bearer vf_…"}}}}
```

**Claude Desktop** — `~/Library/Application Support/Claude/claude_desktop_config.json` takes `command`/`args` (stdio). Custom Connectors accept a URL but offer no custom-header field, so a bearer token needs the `mcp-remote` bridge:

```json
{"mcpServers":{"voxflow":{"command":"npx","args":["-y","mcp-remote","http://127.0.0.1:7331/mcp","--header","Authorization: Bearer vf_…"]}}}
```

#113's criterion says "Claude Desktop **or** Cursor" — Cursor is the direct path and the one to verify first.

## 3. Loopback listener (verified)

Working recipe:

```swift
let parameters = NWParameters.tcp
parameters.requiredInterfaceType = .loopback     // this is what constrains a listener
let listener = try NWListener(using: parameters, on: port)   // port from 7331…7340
```

Measured on this Mac:

| Probe | Result |
|---|---|
| `POST http://127.0.0.1:7331/mcp` without token | `401` |
| `POST http://192.168.178.122:7331/mcp` (LAN IP) | connection refused (curl exit 7) |
| `Origin: https://evil.example` | `403` |
| `GET /mcp` | `405` |
| unknown method | `404` + `{"error":{"code":-32601}}` |
| `server/discover`, `initialize`, `tools/list` | correct JSON-RPC results |

**Gotchas (cost an hour, put them in the plan):**

1. `parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port:)` on a *listener* is a silent trap: the listener reports `.ready`, `listener.port` returns the requested port, and **nothing is bound** (absent from `lsof`, connections refused). Combined with `NWListener(using:on:)` the initializer throws, so the port scan finds "no port free".
2. `lsof` shows `*:7331 (LISTEN)` even with `requiredInterfaceType = .loopback`; the loopback restriction is enforced at accept time, not in the bind address. Verified by the LAN probe above. Belt-and-braces: also drop connections whose `remoteEndpoint` is not loopback.
3. Swift 6: a recursive local `func receive()` captured by an `@Sendable` `NWConnection.receive` completion does not compile ("concurrently-executed local function must be marked `@Sendable`" + non-Sendable capture). Working shape — a `final class … : Sendable` whose only mutable state is a `Mutex<Data>` receive buffer, with `receive()` as a method:

```swift
final class ConnectionHandler: Sendable {
    private let connection: NWConnection
    private let buffer = Mutex(Data())
    private let queue: DispatchQueue
    func start() { connection.stateUpdateHandler = { [self] in if case .ready = $0 { receive() } }; connection.start(queue: queue) }
    private func receive() { connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] chunk, _, done, error in … } }
}
```

4. `stdout` is block-buffered when redirected; a killed probe loses its log. `setvbuf(stdout, nil, _IONBF, 0)` in probes only.
5. HTTP framing: parse until `\r\n\r\n`, then wait for `Content-Length` bytes; answer with `Connection: close` (no keep-alive needed for MCP's one-request-per-POST model).

## 4. Identifying the calling process (verified)

`libproc`, no privileges, no entitlement. From the accepted connection's peer port:

`proc_listallpids` → `proc_pidinfo(pid, PROC_PIDLISTFDS)` → for each `proc_fdinfo` with `proc_fdtype == PROX_FDTYPE_SOCKET`, `proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, …)`, keep `psi.soi_kind == SOCKINFO_TCP`, compare `UInt16(bigEndian:)` of `psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport` to the peer port, then `proc_name(pid, …)`.

Probe output: `PROBE: tools/list from curl (pid 275)` and `PROBE: initialize from Python (pid 276)` — the pid matched the client's own `os.getpid()`. ~30 lines of Swift.

VoxFlow is **not sandboxed** (no `.entitlements` file, nothing in `project.yml`), so this works. If sandboxing is ever added, this breaks and the approval dialog loses the process line.

## 5. What the app already has

`VoxFlow/Settings/MCPSettings.swift` — keys `mcp.enabled` (default off), `mcp.tool.transcribeFile` (on), `mcp.tool.dictate` (on), `mcp.tool.searchHistory` (off); token in Keychain service `dev.artemsem.voxflow`, account `mcp-token`, format `vf_` + 32 lowercase hex, created on first read; `maskedToken` = `vf_` + 12 bullets + last 4; `regenerate()`.

`VoxFlow/Settings/MCPViewModel.swift` — `endpoint = "http://127.0.0.1:7331/mcp"`, `connectedClientsEmptyText = "No clients yet — connect Claude Desktop or Cursor with the token above."`, regenerate alert copy.

`VoxFlow/Settings/MCPSettingsView.swift` — "Enable MCP server", "Lets local AI clients use VoxFlow as a tool. Listens on localhost only.", footnote "Server arrives in a later release." (to be removed), "Access token", "Tools exposed", "Connected clients".

Canvas tool descriptions (ST-06): `transcribe_file` — "Transcribe an audio file at a path; returns text or SRT"; `dictate` — "Start a dictation and return the cleaned-up text"; `search_history` — "Search past dictations — off by default".

Canvas ST-06a: title `"Cursor" wants to use VoxFlow`; body `A local app connected to the MCP server with a valid token. It can use: transcribe_file, dictate.`; line `Process: Cursor (pid 4812) · 127.0.0.1`; buttons `Always allow` / `Allow once` / `Deny`; note "shown even when the window is closed; 'Always allow' adds it to Connected clients".

Canvas 3e: "MCP port busy — 7331 taken → binds 7332…7340, ST-06 shows the actual endpoint with a note; clients must be updated (Copy button)."

`VoxFlowMCP` today is a stub (`MCPModule.name`, `coreVersion`).

Entry points the tools reuse:
- `FileTranscribing.transcribe(_ url: URL, options: TranscriptionOptions, progress: @Sendable @escaping (Double) -> Void) async throws -> TranscriptDocument` (`VoxFlowCore/FileProtocols.swift:30`), implemented by `FileTranscriber`; `TranscriptRenderer` / `OutputFormat` render text or SRT.
- `HistoryService.search(_ query: String) async -> [DictationRecord]` (`VoxFlow/Dictation/HistoryService.swift:118`).
- Dictation has **no programmatic start**: `DictationCoordinator` is `@MainActor` and driven by `fn(_ t: FnTransition)` / a command queue (`escape`, `anyKey`, `pause`, `resume`). A `dictate` tool needs a new seam — the coordinator must expose something like `startProgrammatic() async -> String?` that runs one capture through the same `DictationController` (so the Flow Bar shows it) and returns the inserted text.

## Recommendations

1. Transport: `Network.framework` (`NWListener`, `requiredInterfaceType = .loopback`), no third-party dependency; SwiftNIO is not worth a package dependency for one POST endpoint.
2. Support **both protocol eras** — legacy `initialize` (what Cursor/`mcp-remote` send today) and modern `server/discover` + per-request `_meta`. Advertise both in `supportedVersions`.
3. Answer every request with `application/json`; never open an SSE stream (no server-initiated messages in scope). `tools/call` runs to completion.
4. Split: `VoxFlowMCP` = pure protocol + policy (router, codecs, token compare, Origin/header validation, path policy, client registry rules) with no sockets; the app owns the listener, the peer identity, the approval UI and the three tool implementations.
5. Biggest risks: (a) `dictate` has no existing programmatic seam and touches the concurrency-critical dictation actor; (b) the approval dialog must appear with the main window closed (a floating panel, like MB-00); (c) a long `transcribe_file` competes with dictation for the single whisper queue (#145).
