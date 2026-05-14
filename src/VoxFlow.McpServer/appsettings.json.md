# MCP server `appsettings.json` reference

`appsettings.json` is plain JSON and cannot carry inline comments, so this file documents every option in the `mcp` section. It is the per-option reference paired with [`docs/deployment/mcp-server-security.md`](../../docs/deployment/mcp-server-security.md), which covers the threat model end-to-end. **Read the security doc first** if you are about to expose the server to an MCP client.

Bound to [`McpOptions`](Configuration/McpOptions.cs) at startup. See `Program.cs` for the binding pipeline.

## Top-level options

| Option | Type | Default | Recommended | Notes |
|---|---|---|---|---|
| `enabled` | `bool` | `true` | `true` for any deployed server | Master switch. When `false` the server still starts but tools may refuse. Today there is no shutdown path tied to this; it is a config gate the host can branch on. |
| `transport` | `string` | `"stdio"` | `"stdio"` | The only supported transport. Reserved for future HTTP/socket transports. |
| `serverName` | `string` | `"voxflow"` | Brand-specific (`"voxflow-prod"`, `"voxflow-staging"`) | Advertised to MCP clients via the `serverInfo` handshake. Clients display this. |
| `serverVersion` | `string` | `"1.0.0"` | Pinned to your release | Advertised to MCP clients. Bump on every published change so clients can detect rollouts. |
| `allowBatch` | `bool` | `true` | `false` if you want to disable `transcribe_batch` | Gates the batch-transcription tool. If `false`, only single-file transcription is exposed. |
| `allowedInputRoots` | `string[]` | `[]` | **MUST be populated** for deployed servers | See the [security doc gaps table](../../docs/deployment/mcp-server-security.md#what-pathpolicy-does-not-defend-against) — `[]` means no read restriction. Set this to one or more absolute directory paths. Paths must be **absolute** when `requireAbsolutePaths=true`. |
| `allowedOutputRoots` | `string[]` | `[]` | **MUST be populated** for deployed servers | Same shape and semantics as `allowedInputRoots`, but for write paths (`transcribe_file`'s `outputPath`, batch's output directory). |
| `maxBatchFiles` | `int` | `100` | Sized to your largest legitimate batch | Caps how many files one `transcribe_batch` call processes. Defense against batch-size DoS. Does **not** rate-limit successive calls. |
| `requireAbsolutePaths` | `bool` | `true` | `true` | When `true`, every path passed to a tool must be absolute. Blocks "relative path interpreted against server CWD" attacks. Leave at `true` unless you have a deliberate reason and have audited every caller. |
| `shutdownGracePeriodSeconds` | `int` | `5` | `5`–`30` depending on workload | How long the .NET host waits for in-flight tool invocations to drain on SIGINT/SIGTERM. Maps to `HostOptions.ShutdownTimeout`. Increase if your longest tool call can exceed 5 s and you want clean shutdowns. |

## `resources` subsection

Reserved for future "MCP resources" capability — the server can expose read-only resources (last-run summaries, configuration) to clients without going through a tool call.

| Option | Type | Default | Notes |
|---|---|---|---|
| `resources.enabled` | `bool` | `true` | Master switch for the resources feature. |
| `resources.exposeLastRun` | `bool` | `true` | If `true`, exposes the most recent transcription's metadata as an MCP resource. |

## `prompts` subsection

Same shape — gates predefined MCP prompts.

| Option | Type | Default | Notes |
|---|---|---|---|
| `prompts.enabled` | `bool` | `true` | Master switch for the prompts feature. |

## `logging` subsection

Server-side logging. **Not** filtered through `PathPolicy` — `logFilePath` writes wherever you point it.

| Option | Type | Default | Notes |
|---|---|---|---|
| `logging.minimumLevel` | `string` | `"Information"` | Standard `ILogger` levels: `Trace`, `Debug`, `Information`, `Warning`, `Error`, `Critical`, `None`. |
| `logging.writeToStdErr` | `bool` | `true` | Writes logs to **stderr** (stdout is reserved for the MCP protocol stream). Keep `true` for `stdio` transport. |
| `logging.writeToFile` | `bool` | `false` | When `true`, also writes to `logFilePath`. |
| `logging.logFilePath` | `string` | `""` | File-sink target. Treat as a trusted operator setting — `PathPolicy` does **not** validate this path. |

## Minimal safe config

The shortest config that locks the server down for a single user transcribing `~/Audio/` (expand `~` to the absolute path your shell resolves):

```json
{
  "mcp": {
    "allowedInputRoots":  [ "/Users/YOURNAME/Audio" ],
    "allowedOutputRoots": [ "/Users/YOURNAME/Audio/transcripts" ]
  }
}
```

Every other option keeps its default — the table above lists what those defaults are. For the full worked example with comments, see [`docs/deployment/mcp-server-security.md` § Worked example](../../docs/deployment/mcp-server-security.md#worked-example).

## When you change an option

1. Restart the MCP server — bindings are read once at startup.
2. If you tightened a root, confirm legitimate paths still resolve under the new list. Easy mistake: forgetting to include both the input directory and its `transcripts/` subdirectory when those live in two different trees.
3. For changes to `allowedInputRoots` / `allowedOutputRoots`, run `tests/VoxFlow.McpServer.Tests/PathPolicyTests.cs` against the new shape to confirm the prefix-match contract still holds.
