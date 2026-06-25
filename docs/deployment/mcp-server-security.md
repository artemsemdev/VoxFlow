# MCP server security model

This document explains the security boundary the VoxFlow MCP server enforces, how it is configured, and what it explicitly does not protect against. Read it before deploying `VoxFlow.McpServer` behind an MCP-capable client (Claude Desktop, Cursor, VS Code MCP, etc.).

## Threat model

The MCP server is a stdio process that an MCP-capable client launches and talks to over stdin / stdout. The client passes file paths to the server's tools (`transcribe_file`, `transcribe_batch`, etc.); the server reads input audio, writes output transcripts, and may launch ffmpeg + Python sidecars. The server runs **with the user's full filesystem permissions** — there is no sandbox, no chroot, no seccomp.

The whole protection surface lives in [`PathPolicy`](../../src/VoxFlow.McpServer/Security/PathPolicy.cs): every tool that takes a path passes it through `ValidateInputPath` or `ValidateOutputPath` before touching disk. The policy is configured through the `mcp` section of [`appsettings.json`](../../src/VoxFlow.McpServer/appsettings.json) (see [appsettings reference](../../src/VoxFlow.McpServer/appsettings.json.md)).

### What `PathPolicy` defends against

| Attack | Defense | Source |
|---|---|---|
| **Path traversal via `..`** — `transcribe_file("/Users/me/audio/../../etc/passwd")` | `ContainsDangerousSegments` rejects any path containing `..` before resolution, raising `UnauthorizedAccessException`. | [`PathPolicy.cs:135`](../../src/VoxFlow.McpServer/Security/PathPolicy.cs#L135) |
| **Path traversal via `~`** — `transcribe_file("~/.ssh/id_rsa")` (the .NET runtime does not expand `~`, but a polite-looking path is a red flag). | `ContainsDangerousSegments` rejects any `~`. | [`PathPolicy.cs:135`](../../src/VoxFlow.McpServer/Security/PathPolicy.cs#L135) |
| **Null-byte injection** — `transcribe_file("/safe/path\0/etc/passwd")`. | `ContainsDangerousSegments` rejects any `\0` **before** normalization, so it surfaces as an explicit `UnauthorizedAccessException` policy violation rather than leaking through as a generic IO error. | [`PathPolicy.cs:135`](../../src/VoxFlow.McpServer/Security/PathPolicy.cs#L135) |
| **Reading outside allowed input roots** (when configured) | `IsUnderAnyRoot` checks the normalized path starts with one of the allowed roots. | [`PathPolicy.cs:124`](../../src/VoxFlow.McpServer/Security/PathPolicy.cs#L124) |
| **Writing outside allowed output roots** (when configured) | Same check on the output-root list. | [`PathPolicy.cs:124`](../../src/VoxFlow.McpServer/Security/PathPolicy.cs#L124) |
| **Prefix-match attack** — `/Users/me/audio-evil` satisfying a root of `/Users/me/audio`. | `NormalizeRoots` forces a trailing separator on every configured root, so the `StartsWith` check needs a full segment boundary. | [`PathPolicy.cs:142`](../../src/VoxFlow.McpServer/Security/PathPolicy.cs#L142) |
| **Case-only root bypass on Linux** — `/Home/me/audio/x` satisfying a root of `/home/me/audio` on a case-sensitive filesystem. | Path comparison is `Ordinal` (case-sensitive) on Linux and `OrdinalIgnoreCase` on Windows/macOS, matching each platform's real filesystem semantics. | [`PathPolicy.cs:23`](../../src/VoxFlow.McpServer/Security/PathPolicy.cs#L23) |
| **Relative path tricks** — `transcribe_file("audio/clip.m4a")` interpreted against the server's CWD. | `requireAbsolutePaths=true` (default) forces every path through `Path.IsPathRooted`. | [`PathPolicy.cs:118`](../../src/VoxFlow.McpServer/Security/PathPolicy.cs#L118) |
| **Batch-size DoS** — `transcribe_batch` invoked with a directory holding 10 000 files. | `maxBatchFiles` (default 100) caps how many files one call processes. Enforced inside the batch tool, not in `PathPolicy` itself. | [`McpOptions.cs`](../../src/VoxFlow.McpServer/Configuration/McpOptions.cs) |

### What `PathPolicy` does **NOT** defend against

Read these before deploying — each is a real gap, not a theoretical one.

| Gap | Why it matters | Mitigation |
|---|---|---|
| **Empty `allowedInputRoots` / `allowedOutputRoots` mean no root check at all.** The default `appsettings.json` ships with `[]` for both. With the defaults, any absolute path that survives the traversal/null/relative checks is accepted — including `/etc/`, `~/.ssh/`, anywhere the user has read access. | The default config is **unrestricted by design** because root paths are deployment-specific. The server is "safe" only after you've populated both lists. The server now logs a loud `UNRESTRICTED` warning at startup for each empty list (see [startup diagnostics](#startup-diagnostics)), so this is no longer silent. | Always set `allowedInputRoots` and `allowedOutputRoots` before exposing the server to an MCP client. See [worked example](#worked-example) below. |
| **Symlink traversal.** `Path.GetFullPath` does not resolve symlinks. A symlink inside an allowed root pointing outside still satisfies the check. | If `~/Audio/` is allowed and `~/Audio/secrets -> /etc/` exists, `transcribe_file("~/Audio/secrets/passwd")` is accepted. | Audit your allowed roots for symlinks; for production deployments treat the allow-list as a "trusted directory" promise, not a sandbox. Full symlink hardening is tracked in [#85](https://github.com/artemsemdev/VoxFlow/issues/85). |
| **TOCTOU between policy check and file IO.** `ValidateInputPath` runs before the actual `File.Open*` / ffmpeg launch. A symlink swap between the two is not detected. | Same threat as symlink traversal; same mitigation. The window is small (microseconds) but real. | Restrict file ownership in the allowed roots to the same user running the MCP server. Reducing this window is tracked in [#85](https://github.com/artemsemdev/VoxFlow/issues/85). |
| **No content validation.** `PathPolicy` only checks the path, not what is at the path. A path under an allowed root that points at a malicious WAV crafted to crash ffmpeg or pyannote still gets processed. | Crash / RCE risk is bounded by ffmpeg / pyannote.audio / Whisper.net hardness, not by VoxFlow. | Keep those dependencies up to date. The diarization sidecar is a separate Python process, which limits blast radius to the venv. |
| **No rate limiting / concurrency caps.** Each tool call is processed sequentially per the MCP server, but an MCP client can fire a thousand calls back-to-back. | Disk fill, CPU exhaustion, model-cache thrashing. | `maxBatchFiles` only caps the per-call work. For broader rate limiting, run the server in a wrapper that enforces it. |
| **`logging.writeToFile` writes to whatever path you set.** That path is **not** filtered through `PathPolicy`. | A misconfigured `logFilePath` can write large logs anywhere the server has access. | Treat `logFilePath` as a trusted setting — only operators (you) should ever change it. |

## Startup diagnostics

At startup the server logs the **effective** path policy to stderr (stdout is the MCP protocol stream) via [`PathPolicyDiagnostics`](../../src/VoxFlow.McpServer/Security/PathPolicyDiagnostics.cs). The intent is that running unrestricted is never silent.

- Each configured root list is logged at `Information` with its entries.
- Each **empty** root list is logged at `Warning` as `MCP input/output access is UNRESTRICTED: no allowedInputRoots/allowedOutputRoots configured …`.
- `requireAbsolutePaths=false` is logged at `Warning`.

With the shipped defaults (`[]` for both lists) you will see two `UNRESTRICTED` warnings on every launch. That is expected until you populate the allow-lists — see the [worked example](#worked-example). Capture stderr from your MCP client's server logs to confirm the policy your deployment is actually running.

### Case sensitivity

Root matching uses case-sensitive (`Ordinal`) comparison on Linux and case-insensitive (`OrdinalIgnoreCase`) comparison on Windows and macOS, matching each platform's default filesystem. This is intentional: on Linux `/Home` and `/home` are different directories, so a case-insensitive compare would let an attacker satisfy an allowed root by changing case. The behavior is asserted in [`PathPolicyTests`](../../tests/VoxFlow.McpServer.Tests/PathPolicyTests.cs) (`ValidateInputPath_CaseSensitivity_MatchesHostFileSystem`). If your allow-list and the real path disagree only by case on Linux, the path is rejected.

## Per-option reference

See [`src/VoxFlow.McpServer/appsettings.json.md`](../../src/VoxFlow.McpServer/appsettings.json.md) for every option in the `mcp` section: default, recommended value, what attack it prevents, and what happens when set permissively.

## Worked example

Scenario: you want the MCP server to transcribe files in `~/Audio/` and write transcripts to `~/Audio/transcripts/`. Nothing else.

```jsonc
{
  "mcp": {
    "enabled": true,
    "transport": "stdio",

    // PathPolicy gates — the heart of the security boundary.
    "allowedInputRoots":  [ "/Users/YOURNAME/Audio" ],
    "allowedOutputRoots": [ "/Users/YOURNAME/Audio/transcripts" ],
    "requireAbsolutePaths": true,

    // Batch-DoS cap; tune to the largest legitimate batch you expect.
    "maxBatchFiles": 100,
    "allowBatch": true,

    // Optional advertisement; clients display these to the user.
    "serverName": "voxflow",
    "serverVersion": "1.0.0",

    // Logging — `writeToFile` writes wherever you point it; not gated by PathPolicy.
    "logging": {
      "minimumLevel": "Information",
      "writeToStdErr": true,
      "writeToFile": false,
      "logFilePath": ""
    }
  }
}
```

Notes:
- **Absolute paths only.** The defaults `~/Audio` and `~/Audio/transcripts` do **not** work — `~` is rejected by `ContainsTraversalSegments`. Use the fully expanded path (`/Users/yourname/Audio` on macOS, `/home/yourname/Audio` on Linux).
- **Output root nested under input root is fine.** The lists are checked independently.
- **Want read-only?** Leave `allowedOutputRoots = []` and the server will refuse every write — but every tool that writes (`transcribe_file`, `transcribe_batch`) will fail. There is currently no read-only mode flag; emptying output roots is the closest equivalent and breaks the write tools.

## Limits (gaps acknowledged)

This is the short list of attacks `PathPolicy` cannot block, intended for explicit acknowledgement before deployment:

1. **Empty allow-lists = no restriction** — see the top of the gaps table above. The default config is intentionally permissive; restricting it is the operator's job. The server now logs a loud `UNRESTRICTED` warning at startup for each empty list, so this is surfaced rather than silent.
2. **Symlinks inside allowed roots** — `PathPolicy` does not call `realpath()` / `Path.GetFullPath` does not resolve symlinks. Audit the roots manually. Hardening tracked in [#85](https://github.com/artemsemdev/VoxFlow/issues/85).
3. **TOCTOU races** — micro-window between path validation and file IO. Restrict ownership of the allowed roots to the server's user account. Reducing the window is tracked in [#85](https://github.com/artemsemdev/VoxFlow/issues/85).
4. **Content-level attacks** — malicious media files can still trigger crashes / OOM in ffmpeg / pyannote / Whisper.net. Keep those dependencies current.
5. **No per-client identity** — the MCP stdio transport has no notion of "which client is calling". Every connection has the same privileges.
6. **No audit log of denied requests** — `UnauthorizedAccessException` is thrown, the MCP client gets an error envelope, but there is no structured log of "client X tried to read /etc/passwd at T". `logging.writeToStdErr` captures the operational stderr, not denied-request audit. Track via the host's stderr capture if needed.

## Reference implementation

- Path validation: [`src/VoxFlow.McpServer/Security/PathPolicy.cs`](../../src/VoxFlow.McpServer/Security/PathPolicy.cs).
- Startup diagnostics: [`src/VoxFlow.McpServer/Security/PathPolicyDiagnostics.cs`](../../src/VoxFlow.McpServer/Security/PathPolicyDiagnostics.cs).
- Option binding: [`src/VoxFlow.McpServer/Configuration/McpOptions.cs`](../../src/VoxFlow.McpServer/Configuration/McpOptions.cs).
- Composition root and DI wiring: [`src/VoxFlow.McpServer/Program.cs`](../../src/VoxFlow.McpServer/Program.cs).
- Test coverage: [`tests/VoxFlow.McpServer.Tests/PathPolicyTests.cs`](../../tests/VoxFlow.McpServer.Tests/PathPolicyTests.cs).

## Related

- [Error catalog](../runbooks/error-catalog.md) — the `Path is not under any allowed … root` / `Path contains traversal or injection sequences` / `Path must be absolute` patterns are listed there with their throwing lines.
- [Speaker labeling runbook](../runbooks/speaker-labeling.md) — the diarization sidecar runs as a separate Python process started by VoxFlow.Core, **not** by the MCP server directly; its security boundary is "what the venv can do as the local user".
