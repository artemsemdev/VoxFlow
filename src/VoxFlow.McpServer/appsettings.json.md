# MCP server `appsettings.json` reference

`appsettings.json` is plain JSON and cannot carry inline comments, so this file documents every option in the `mcp` section. It is the per-option reference paired with [`docs/deployment/mcp-server-security.md`](../../docs/deployment/mcp-server-security.md), which covers the threat model end-to-end. **Read the security doc first** if you are about to expose the server to an MCP client.

Bound to [`McpOptions`](Configuration/McpOptions.cs) at startup. See `Program.cs` for the binding pipeline.

## Top-level options

| Option | Type | Default | Recommended | Notes |
|---|---|---|---|---|
| `enabled` | `bool` | `true` | `true` for any deployed server | Master switch. When `false`, the server logs `disabled via mcp.enabled=false` to stderr and exits cleanly without starting — it does not serve. |
| `transport` | `string` | `"stdio"` | `"stdio"` | The only supported transport. **Validated at startup**: any other value (e.g. `http`) fails fast with an actionable error rather than silently falling back to stdio. |
| `serverName` | `string` | `"voxflow"` | Brand-specific (`"voxflow-prod"`, `"voxflow-staging"`) | Advertised to MCP clients via the `serverInfo` handshake. Clients display this. |
| `serverVersion` | `string` | `"1.0.0"` | Pinned to your release | Advertised to MCP clients. Bump on every published change so clients can detect rollouts. |
| `allowBatch` | `bool` | `true` | `false` if you want to disable `transcribe_batch` | Gates the batch-transcription tool. If `false`, only single-file transcription is exposed. |
| `allowedInputRoots` | `string[]` | `[]` | **MUST be populated** for deployed servers | See the [security doc gaps table](../../docs/deployment/mcp-server-security.md#what-pathpolicy-does-not-defend-against) — `[]` means no read restriction. An empty list logs a loud `UNRESTRICTED` warning at startup. Set this to one or more absolute directory paths. Paths must be **absolute** when `requireAbsolutePaths=true`. On Linux, root matching is case-sensitive (see [§ Case sensitivity](../../docs/deployment/mcp-server-security.md#case-sensitivity)). |
| `allowedOutputRoots` | `string[]` | `[]` | **MUST be populated** for deployed servers | Same shape and semantics as `allowedInputRoots`, but for write paths (`transcribe_file`'s `outputPath`, batch's output directory). Empty also logs an `UNRESTRICTED` warning at startup. |
| `maxBatchFiles` | `int` | `100` | Sized to your largest legitimate batch | Caps how many files one `transcribe_batch` call processes. Defense against batch-size DoS. Does **not** rate-limit successive calls. |
| `requireAbsolutePaths` | `bool` | `true` | `true` | When `true`, every path passed to a tool must be absolute. Blocks "relative path interpreted against server CWD" attacks. Leave at `true` unless you have a deliberate reason and have audited every caller. |
| `shutdownGracePeriodSeconds` | `int` | `5` | `5`–`30` depending on workload | How long the .NET host waits for in-flight tool invocations to drain on SIGINT/SIGTERM. Maps to `HostOptions.ShutdownTimeout`. Increase if your longest tool call can exceed 5 s and you want clean shutdowns. |

## `resources` subsection

Gates the read-only configuration-inspection tool `get_effective_config`, which returns the resolved VoxFlow configuration to the client.

| Option | Type | Default | Notes |
|---|---|---|---|
| `resources.enabled` | `bool` | `true` | When `true`, the `get_effective_config` tool is registered. Set `false` to keep the server from disclosing the effective configuration; the core transcription tools are unaffected. Enforced in `McpServerConfigurator.ApplyCapabilities()`. |

> `resources.exposeLastRun` was **removed** in #71. It was never implemented (no MCP-resource backed it) and implied an unsupported capability. Remove it from any config you copied from an older version — unknown keys bind to nothing.

## `prompts` subsection

Gates the predefined MCP prompts (`WhisperMcpPrompts`).

| Option | Type | Default | Notes |
|---|---|---|---|
| `prompts.enabled` | `bool` | `true` | When `true`, the guided prompts are registered. When `false`, no prompts are exposed to the client. Enforced in `McpServerConfigurator.ApplyCapabilities()`. |

## `logging` subsection

Server-side logging, applied to the host logging providers at startup. Logs go to stderr and/or a file — **never stdout** (reserved for the MCP protocol stream). `logFilePath` is **not** filtered through `PathPolicy` — it writes wherever you point it.

| Option | Type | Default | Notes |
|---|---|---|---|
| `logging.minimumLevel` | `string` | `"Information"` | Standard `ILogger` levels: `Trace`, `Debug`, `Information`, `Warning`, `Error`, `Critical`, `None`. **Validated at startup** — an unknown level fails fast. |
| `logging.writeToStdErr` | `bool` | `true` | When `true`, logs are written to **stderr**. Keep `true` for `stdio` transport. With both this and `writeToFile` `false`, the server runs without any log sink. |
| `logging.writeToFile` | `bool` | `false` | When `true`, logs are appended to `logFilePath`. Requires a non-empty `logFilePath` — otherwise startup fails fast. |
| `logging.logFilePath` | `string` | `""` | File-sink target (opened append). Treat as a trusted operator setting — `PathPolicy` does **not** validate this path. Required when `writeToFile` is `true`. |

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
