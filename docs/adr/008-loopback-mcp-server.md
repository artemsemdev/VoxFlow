# ADR-008: Loopback MCP server

Status: Accepted · Date: 2026-09-10

## Context

The design spec (§2/§3) and canvas ST-06/ST-06a/ST-06r/3e call for VoxFlow to expose itself as a
local AI-client tool over MCP: Cursor (and Claude Desktop, through `mcp-remote`) should be able to
connect with a token copied from Settings › MCP Server and call `transcribe_file`, `dictate` and
`search_history` — the last off by default — subject to a per-client approval dialog and a path
policy that keeps `transcribe_file` away from anything the user did not already mean to share.
Issue #113. A spike (`docs/superpowers/plans/2026-09-10-phase6-mcp-spike-notes.md`) measured the
current MCP wire protocol against a throwaway probe package before any of this was built, and its
facts — the two protocol eras, the working `NWListener` recipe and its three gotchas, the `libproc`
peer-resolution sequence, and the exact client config snippets — are what the decision below is
built on.

Phase 6 (`docs/superpowers/plans/2026-09-10-phase6-mcp-server.md`) split the work into a pure
protocol/policy package (`VoxFlowMCP` — JSON-RPC, router, HTTP policy, tool descriptors, path
policy, client-registry rules; no sockets) and an app layer (`LoopbackListener`, `PeerIdentity`,
the three tool implementations, the ST-06a approval panel, Settings wiring) over four
implementation tasks, each reviewed; this task adds the one integration test that exercises the
whole stack over a real socket, and records the resulting design as this ADR.

## Decision

- **Two protocol eras, one router.** The MCP spec moved to per-request version negotiation on
  2026-07-28 (`server/discover`, `params._meta["io.modelcontextprotocol/protocolVersion"]`,
  `MCP-Protocol-Version`/`Mcp-Method`/`Mcp-Name` headers that must agree with the body). Real
  clients today — Cursor, `mcp-remote` for Claude Desktop — still speak the older `initialize` →
  `notifications/initialized` → `tools/list`/`tools/call` handshake. `MCPRouter` answers both:
  `supportedVersions: ["2026-07-28", "2025-06-18"]`, `server/discover` and `initialize` both
  resolve to a result, and a request is recognized as legacy purely by the *absence* of `_meta`'s
  version key rather than any explicit "which era" flag. The legacy path is the one that has to
  work end to end (it is what the integration test and the owner checklist actually drive); the
  modern path is answered correctly but only unit-tested, since nothing that connects to VoxFlow
  today speaks it.
- **HTTP policy is a pure function ahead of routing.** `MCPHTTPPolicy.verdict(for:token:boundPort:)`
  checks, in order: path (`/mcp` or `404`), method (`POST` only — `GET`/`DELETE`/anything else is
  `405`), `Origin` (absent is fine; present and not `http://127.0.0.1[:port]`/`http://localhost[:port]`
  is `403`), bearer token (constant-time compare against the one token in the Keychain; missing or
  wrong is `401`), then JSON-RPC body parse (`400`/`-32700`), then — only for a modern request — that
  its headers agree with its body (`400`/`-32020`) and its version is supported
  (`400`/`UnsupportedProtocolVersionError`). Every answer is `Content-Type: application/json`,
  `Connection: close`; the server never opens an SSE stream or tracks a session (`Mcp-Session-Id`
  and `Last-Event-ID` are accepted and ignored) — the whole surface is one POST in, one JSON object
  out, which is all three tools need.
- **Loopback binding via `requiredInterfaceType`, not `requiredLocalEndpoint`.** The listener is
  `NWParameters.tcp` with `requiredInterfaceType = .loopback`, then `NWListener(using:on:)`,
  scanning ports 7331…7340 for the first one that reaches `.ready`. The spike's first gotcha is why:
  `parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port:)` on a *listener* is a
  silent trap — the listener reports `.ready` and `.port` returns the requested port, but nothing is
  actually bound (absent from `lsof`, every connection refused), so a port-scan loop built on it
  would report "no port free" even on an idle machine. Belt-and-braces on top of the interface
  restriction, `LoopbackListener` also drops any accepted connection whose peer endpoint isn't
  loopback, because `lsof` shows the socket bound on all interfaces even under
  `requiredInterfaceType = .loopback` — the restriction is enforced at accept time, not in the bind
  address. `NWListener(using:on:)` does not throw on a busy port either; the failure surfaces later,
  asynchronously, via `stateUpdateHandler` (`EADDRINUSE`), so the scan actually awaits each
  candidate's `.ready`/`.failed` rather than trusting the initializer not throwing. When the bound
  port isn't 7331, ST-06 shows the real endpoint and the note "Port 7331 was busy — update your
  client with the Copy button" (canvas 3e).
  Startup callers share one attempt. Stopping cancels its pending candidate immediately and
  invalidates every joined caller; an old caller cannot initiate a new scan or accept a delayed
  connection after stop. A new explicit start can bind independently of the old attempt's completion.
  The service also fences lazy startup before transport creation and after every transport await.
  Client-store initialization is shared for the service lifetime, and every transport uses the same
  runner for routing, bound-port updates and session resets. Stop detaches the old transport before
  awaiting it; obsolete completions cannot change a replacement or newer Settings operation.
  Socket-free lifecycle regressions use controlled candidates; real port/HTTP coverage is opt-in
  via `TEST_RUNNER_VOXFLOW_MCP_INTEGRATION=1` (see CONTRIBUTING.md).
- **`libproc` peer identity, sandbox-dependent.** `LibprocPeerResolver` walks every process's open
  file descriptors (`proc_listallpids` → `PROC_PIDLISTFDS` → `PROC_PIDFDSOCKETINFO`) looking for an
  *established* TCP socket whose local port matches the accepted connection's peer port **and**
  whose foreign port matches VoxFlow's own bound port, then reads that process's name and path
  (`proc_name`/`proc_pidpath`). Matching the peer port alone was the original shape; a review
  amended it to match both ends of an established socket, because a port-only match could
  mis-attribute a connection to an unrelated process that merely reused the same local port number
  after the real client's ephemeral port was recycled by the kernel. A second match for the same
  pair, or a failed name lookup, resolves to `nil` — an unidentified client is judged safer than a
  confidently wrong one. This works with no privilege and no entitlement, but only because VoxFlow
  ships unsandboxed; see Consequences.
- **Approval is keyed on client identity, not a connection.** ST-06a shows a floating,
  non-activating panel (so it works with the main window closed) on a first call from an unknown
  client: title `"{name}" wants to use VoxFlow`, body naming the enabled tools, a
  `Process: {name} (pid {pid}) · 127.0.0.1` line, and `Always allow`/`Allow once`/`Deny`. The
  approval *key* is process name + executable path (`ClientRegistry.key`), never the pid — a
  relaunched client keeps its approval, and `mcp_clients`' `UNIQUE(name, path)` constraint enforces
  the same identity everywhere. Two rulings were amended during implementation review, both because
  the tool seam only ever sees a resolved *client identity*, never the underlying TCP connection:
  `Allow once` cannot be scoped to "the rest of this one connection" (there is no connection object
  by the time a tool body runs), so it is scoped to the rest of the app session instead, and is
  never written to `mcp_clients`; and when peer resolution fails entirely, every such client
  displays as the same "Unknown app" identity, so `Always allow` is not offered for it — persisting
  one would silently approve every future unidentifiable process at once, so an unresolved client
  can only ever be allowed for the session. `Deny` answers `-32001` and is remembered for the
  session without a dialog reappearing; an approval request waiting on a decision times out after
  60 s with the same `-32001`.
- **`mcp_clients`: a row means persistent access.** Migration `v3` adds
  `mcp_clients(id, name, path, approved, first_seen, last_seen, UNIQUE(name, path))`, unencrypted
  (it holds no dictation content). `MCPClientStore.approve` is the only call that ever inserts a
  row (an upsert, so a client approved twice keeps one row); `touchLastSeen` only ever updates an
  *existing* row's timestamp and never inserts one, so a client that connects but is denied, or
  whose first call is still pending a decision, never appears in ST-06's "Connected clients" list —
  the canvas is explicit that approving is what puts a client there. `revoke`/`revokeAll` delete,
  keeping "a row exists" and "is approved" the same fact rather than two that can drift apart.
- **Tools, each gated twice.** `transcribe_file({path, format?})`, `dictate({})` and
  `search_history({query, limit?})` are each behind both the Settings toggle (`mcp.tool.*`) and
  client approval; a disabled tool is absent from `tools/list` and the runner re-checks on every
  `tools/call` (not only at `tools/list` time), so flipping a toggle off takes effect on the very
  next call. `transcribe_file` and `search_history` reuse the existing `FileTranscribing`/
  `HistoryService` pipelines and render one `content: [{type: "text", text}]` block.
  `search_history` is off by default (spec) and skips unreadable rows the same way the History page
  does. `dictate` needed a new seam — `DictationController.results()`, an `AsyncStream` broadcast
  fed wherever `onSave` already runs, and `DictationCoordinator.startProgrammaticDictation()`,
  which starts the same hands-free capture the hotkey does (the Flow Bar shows it; the result is
  inserted and saved exactly as a normal dictation) — rather than a parallel code path that could
  drift from what a real dictation does. Two rulings were amended here too: `dictate` fails fast
  with `-32005` and the capture's own readable reason (Escape, an empty transcript, no microphone,
  an excluded app, no installed model) instead of holding the caller for the whole timeout budget,
  because a caller has no way to distinguish "still recording" from "hung" otherwise; and the
  transport's connection watchdog (20 minutes) is a last-resort guard against a handler that never
  returns at all, not a per-request timeout — the transport does not know which tool a request
  names or how long that tool's own budget should be (`dictate`'s is `FlowBarConfig.maxDuration +
  processingTimeout`, ~920 s by default; `transcribe_file` on a long recording can take minutes),
  so each tool owns its own timeout and the watchdog only exists well above every one of them.
- **Everything expensive happens after authentication.** The final review found three separate
  ways an unauthenticated local process could spend the server's resources, and the answers are
  all the same shape: do less before the token is checked. The receive buffer is capped (16 KB of
  headers, 1 MB of request, then `413`) and the header block is decoded exactly once no matter how
  a peer chunks it; the deadline for delivering a whole request is **absolute** — armed once when
  a connection becomes ready and never refreshed by arriving bytes, because refreshing it let
  sixteen byte-dripping sockets hold every connection slot indefinitely; and the peer's process is
  resolved lazily through `MCPPeer`, from inside the authenticated path only, because that
  resolution walks every process's file descriptors (~5 ms, ~14,000 syscalls) and doing it on
  accept turned a bare `connect()` loop into unbounded pre-auth CPU work.
- **Regenerating the token forgets session grants too.** `revokeAll()` deletes the persistent
  approvals, but "Allow once" grants and session denials live in the running `MCPToolRunner`, so
  regenerating also calls `clearSessionDecisions()`. Without it a client that had been allowed
  once was silently re-admitted with no dialog, which the ST-06r copy and the runbook both promise
  cannot happen.
- **`PathPolicy`: no "grant a folder" flow.** `transcribe_file`'s path is checked after resolving
  symlinks (so a symlink inside the home directory pointing outside it is judged by its target, not
  its own location) against three rules: inside the user's home directory, not under `~/Library`,
  and carrying one of the extensions the Files pipeline already supports. Everything else answers
  `-32602` with the rejection's exact reason. No path is ever remembered between calls — the canvas
  has no folder-grant UI, so there is none in this policy either.
- **No outbound network, ever.** The server only ever accepts loopback connections and answers
  them; it never itself opens a connection anywhere. A test asserts `VoxFlowMCP` contains no
  `URLSession`/`NWConnection(to:)` use. Local MCP replies are excluded from the privacy footer's
  measured model-download request bytes, which are tracked separately by the downloader.

## Consequences

- **Sandboxing would break ST-06a's process line.** `LibprocPeerResolver` works today because
  VoxFlow ships with no `.entitlements` file and nothing in `project.yml` requests the App Sandbox.
  If sandboxing is ever added, `libproc`'s process-table walk stops working, `resolveProcess`
  degrades to `nil` for every client, and every connection displays as "Unknown app" with no pid —
  which also means `Always allow` stops being offered at all (per the ruling above), so every
  client would need re-approving every session. Any future sandboxing decision has to budget for
  this loss or find a replacement identity mechanism first.
- **`transcribe_file` competes with dictation for the single whisper queue (#145).** Both go
  through the same whisper.cpp engine instance; there is no scheduling between an MCP-triggered file
  transcription and a hotkey dictation arriving at the same moment. A long `transcribe_file` call
  can make a concurrent dictation wait, and vice versa — tracked as a follow-up rather than solved
  here.
- **`mcp-remote` is a required bridge for Claude Desktop, not a nicety.** Claude Desktop's Custom
  Connectors accept a URL but have no field for a custom header, so there is no way to hand it a
  bearer token directly. Until Claude Desktop supports custom headers natively, connecting it to
  VoxFlow means running `npx -y mcp-remote http://127.0.0.1:<port>/mcp --header "Authorization:
  Bearer <token>"` as the configured command — an extra moving part (a Node process, a network
  round trip through `mcp-remote` even though the ultimate destination is loopback) that Cursor's
  direct-HTTP path doesn't need.
- **The Keychain token is the only credential — regenerating it is a blunt instrument.** There is
  no per-client secret; every connected client authenticates with the same token from Settings ›
  MCP Server. Regenerating it (ST-06r) is therefore defined to drop every approved row in
  `mcp_clients`, not just invalidate the old token value — a client "is" the fact that it holds a
  token that used to be valid, so keeping stale approvals around after a regenerate would let an
  old, now-unauthenticated client's *identity* stay approved for a token it can no longer present.
  The practical effect: regenerating disconnects Cursor and Claude Desktop both, and the owner has
  to paste the new token into each client and get re-approved through ST-06a again.
- **The router now carries two protocol eras indefinitely.** `MCPRouter` has to keep answering both
  `initialize` and `server/discover` for as long as any real client still speaks the legacy
  handshake; there is no version-sunset mechanism here, so this needs revisiting (and likely
  re-testing against whichever era Cursor/`mcp-remote` speak by then) as clients migrate to the
  2026-07-28 revision.

## Related

- [ADR-002](002-whisper-cpp-speech-engine.md) — the whisper.cpp engine `transcribe_file` and
  dictation both queue against (Consequences, #145).
- `docs/superpowers/plans/2026-09-10-phase6-mcp-server.md` — the ten binding rulings this ADR
  restates in prose, and the per-task implementation record.
- `docs/superpowers/plans/2026-09-10-phase6-mcp-spike-notes.md` — the measured protocol facts, the
  `NWListener` recipe and its three gotchas, the `libproc` sequence, and the client config snippets
  the runbook quotes verbatim.
- `docs/runbooks/connect-an-mcp-client.md` — connecting Cursor and Claude Desktop, the approval
  dialog, revoking a client, and what to do when the port moves.
- Design canvas ST-06 (Settings › MCP Server, PDF page 6), ST-06a (client approval, page 5), ST-06r
  (regenerate, page 5), 3e (port-busy note). Issue #113.
