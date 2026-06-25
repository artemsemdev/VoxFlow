# Risks, Assumptions, and Open Questions

> Honest assessment of what the architecture depends on, where it is exposed, and what remains unresolved.

Implementation snapshot: 2026-06-25.

## Assumptions

These are conditions the architecture depends on that are not enforced by the system itself.

### A1. Whisper.net native runtime remains stable

The transcription pipeline depends on Whisper.net (v1.9.0) and its bundled libwhisper native binaries. The architecture assumes:

- The native runtime works reliably on both Apple Silicon and Intel macOS
- `WhisperFactory` and `WhisperProcessor` are safe to reuse within a single process
- `processor.ChangeLanguage()` is safe to call between inference passes

**Mitigation:** The Intel Mac Catalyst CLI bridge (ADR-021) was introduced specifically because the in-process Whisper runtime was unreliable under Mac Catalyst on Intel. This demonstrates a willingness to work around native runtime issues at the host level.

### A2. ffmpeg is available and correctly installed

All audio conversion depends on ffmpeg as an external process. The architecture assumes:

- ffmpeg is installed and accessible on `PATH` or at a configured path
- ffmpeg supports the configured audio filter chain and output format
- ffmpeg handles the input audio format correctly

**Mitigation:** Startup validation checks ffmpeg availability before processing begins (ADR-008). If ffmpeg is missing or broken, the system fails fast with a clear message.

### A3. Local file system is the sufficient persistence layer

VoxFlow uses the local file system for all state: configuration, models, intermediate audio, and transcript output. There is no database. The architecture assumes:

- File paths are writable and have sufficient disk space
- No concurrent access to the same output files
- File system permissions are adequate for the current user

**Mitigation:** Startup validation probes key directories for writability. Batch temp files use GUID-suffixed names to avoid collisions.

### A4. Single-user, single-instance execution

The system assumes one user runs one instance at a time. There is no:

- File locking on output or temp files
- Concurrent access protection for the Whisper model file
- Instance detection or singleton enforcement

**Mitigation:** This is appropriate for a local developer tool. If concurrent execution is needed, it would require file locking and potentially model instance pooling.

### A5. macOS is the only Desktop platform

The Desktop host targets `net9.0-maccatalyst` exclusively. The architecture assumes:

- MAUI Blazor Hybrid works reliably on Mac Catalyst
- AppleScript accessibility automation is available for UI testing
- Platform-specific features (native drop, file picker, Finder integration) are macOS-only

**Mitigation:** Core business logic is platform-agnostic. Adding Linux or Windows Desktop hosts would require new MAUI targets and platform-specific UI code, but no Core changes.

## Risks

### R1. Native runtime version coupling

**Risk:** Whisper.net upgrades may change native library behavior, introduce regressions, or drop support for older macOS versions.

**Impact:** Transcription may fail or produce different results after a Whisper.net update.

**Current state:** Pinned to Whisper.net 1.9.0. No automated compatibility testing across Whisper.net versions.

**Mitigation options:** Pin the version (current approach); add regression tests with known audio/transcript pairs; run smoke tests after dependency updates.

### R2. Intel Mac Catalyst CLI bridge fragility

**Risk:** The Intel CLI bridge depends on a working `dotnet` host and a buildable or pre-built `VoxFlow.Cli` at the expected path. If the CLI binary is missing, outdated, or the `dotnet` runtime is not available, Desktop transcription fails on Intel.

**Impact:** Intel Mac users cannot transcribe files in the Desktop app.

**Current state:** The `BuildDesktopCliBridge` MSBuild target rebuilds CLI during Desktop builds. Desktop startup does not validate CLI availability independently.

**Mitigation options:** Add a Desktop startup check for CLI bridge health; bundle the CLI binary inside the Desktop `.app`.

### R3. AppleScript UI automation is fragile

**Risk:** macOS UI automation via AppleScript and Accessibility depends on specific UI element names, window titles, and system permissions. macOS updates may break element identifiers or change Accessibility behavior.

**Impact:** Desktop UI tests fail after macOS updates, giving false negatives.

**Current state:** Tests use element identifiers where possible. Accessibility permissions must be granted manually.

**Mitigation options:** Accept this as inherent to macOS UI automation; keep the UI test suite small and focused on critical paths; add diagnostic screenshots on failure (already implemented).

### R4. No code signing or notarization

**Risk:** Unsigned macOS app bundles trigger Gatekeeper warnings and may be quarantined by macOS. Users must manually override security warnings to run the app.

**Impact:** Poor first-run experience for users who receive the packaged `.app` or `.pkg`.

**Current state:** `scripts/build-macos.sh` produces local artifacts without signing or notarization.

**Mitigation options:** Add signing and notarization to the build pipeline when external distribution is needed. For development, `dotnet run` avoids the issue entirely.

### R5. MCP protocol evolution

**Risk:** The Model Context Protocol is evolving. Future MCP specification changes may deprecate current tool/prompt patterns or require new capabilities (resources, sampling, etc.).

**Impact:** MCP client compatibility issues; need to update the MCP server implementation.

**Current state:** Uses `ModelContextProtocol` NuGet v1.1.0. Exposes 7 tools and 4 prompts. No first-class MCP resources. `McpOptions` is partially enforced: server identity, path roots, absolute-path policy, batch limits, and shutdown timeout are active, while `enabled`, unsupported `transport` values, prompt/resource toggles, and the `logging` subsection are not fully enforced yet.

**Mitigation options:** The MCP server is a thin host. Protocol updates affect only the MCP project, not Core or other hosts. Treat the unenforced options as implementation debt until they are either wired, validated as unsupported, or removed from user-facing config.

### R6. Full audio buffer in memory

**Risk:** Very large audio files (multi-hour recordings, high-quality formats) may exhaust available memory when `WavAudioLoader` reads the entire file into a `float[]` array.

**Impact:** `OutOfMemoryException` for unusually large files.

**Current state:** Acceptable for typical use (1-hour recordings use ~400 MB total). No streaming alternative exists.

**Mitigation options:** Add a file-size preflight check to startup validation; implement streaming WAV loading if large-file support becomes a requirement.

## Open Questions

### Q1. Should batch processing be exposed in the Desktop UI?

Batch processing is fully implemented in `VoxFlow.Core` and available via CLI and MCP, but the Desktop app only supports single-file transcription. The question is whether Desktop users need batch capability, and if so, what the UX should be (queue, folder picker, progress per file).

**Current decision:** Deferred. Desktop scope is explicitly single-file for now.

### Q2. Should the MCP server support HTTP/SSE transport?

The MCP server is stdio-only (ADR-017). HTTP transport would enable remote MCP clients but introduces authentication, CORS, port management, and network surface area — all of which conflict with the local-only security model.

**Current decision:** Deferred until a concrete use case requires remote MCP access.

### Q3. Are the current structured output formats sufficient?

Transcript output is no longer plain-text-only. `resultFormat` supports:

- `txt` - legacy `{start}->{end}: {text}` output
- `srt` - SubRip subtitles
- `vtt` - WebVTT subtitles
- `json` - structured transcript metadata and segments
- `md` - human-readable Markdown

When speaker labeling is enabled and succeeds, VoxFlow also writes a versioned `{resultPath}.voxflow.json` artifact containing the full `TranscriptDocument`.

**Current decision:** Implemented for the known consumers. Future output formats, schema revisions, or richer export contracts should be additive unless there is a documented breaking-change reason.

### Q4. What is the model download strategy for Desktop distribution?

The Desktop app currently expects the Whisper model to be present on disk or downloaded on first use. For a distributed `.app`, the question is whether the model should be bundled (large app size), downloaded on first launch (requires network), or managed separately.

**Current decision:** Not resolved. The current approach (download on first use) works for development but may not be acceptable for end-user distribution.

### Q5. What is the long-term strategy for Intel Mac support?

Intel Mac support via the CLI bridge is a workaround for Whisper.net instability under Mac Catalyst x64. As Intel Macs age out of the user base, the question is when to drop Intel-specific code paths.

**Current decision:** Maintained for now. The CLI bridge is isolated in the Desktop host and does not complicate Core.
