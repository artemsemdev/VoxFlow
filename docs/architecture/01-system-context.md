# System Context View

> C4 Level 1 — How VoxFlow fits into its environment.

## Context Diagram

```mermaid
C4Context
    title System Context — VoxFlow

    Person(operator, "Operator", "Developer or user running local transcription")
    Person(desktop_user, "Desktop User", "macOS user running visual transcription workflow")
    Person(ai_client, "AI Client", "Claude, ChatGPT, GitHub Copilot, VS Code")

    System(core, "VoxFlow.Core", ".NET 9 shared library<br/>Transcription services, DI, interfaces")
    System(cli, "VoxFlow.Cli", ".NET 9 console application<br/>Thin CLI host using Core via DI")
    System(mcp_server, "VoxFlow.McpServer", ".NET 9 MCP server<br/>Exposes Core via Model Context Protocol")
    System(desktop, "VoxFlow.Desktop", ".NET 9 MAUI Blazor Hybrid<br/>macOS desktop app with visual workflow")

    System_Ext(ffmpeg, "ffmpeg", "External process<br/>Audio format conversion and filtering")
    System_Ext(whisper_runtime, "Whisper.net + libwhisper", "In-process native library<br/>Speech-to-text inference via GGML models")
    SystemDb_Ext(filesystem, "Local File System", "Audio inputs, GGML models, config, transcript outputs")

    Rel(operator, cli, "Runs via CLI", "dotnet run / compiled binary")
    Rel(desktop_user, desktop, "Uses macOS app", "File picker, drag-and-drop")
    Rel(ai_client, mcp_server, "Invokes via MCP stdio", "JSON-RPC over stdin/stdout")
    Rel(cli, core, "Uses via DI", "AddVoxFlowCore()")
    Rel(mcp_server, core, "Uses via DI", "AddVoxFlowCore()")
    Rel(desktop, core, "Uses via DI", "AddVoxFlowCore()")
    Rel(core, ffmpeg, "Spawns child process", ".m4a → 16kHz mono .wav")
    Rel(core, whisper_runtime, "P/Invoke via Whisper.net", "Load model, run inference")
    Rel(core, filesystem, "Read/Write", "Config, audio, models, transcripts")
```

## Actors and External Systems

| Actor / System | Type | Interaction | Trust Level |
|---------------|------|-------------|-------------|
| Operator | Human | Configures `appsettings.json`, invokes CLI, reads output | Full trust (local user) |
| Desktop User | Human | Uses macOS desktop app for visual transcription workflow | Full trust (local user) |
| AI Client | Software | Discovers and invokes tools via MCP stdio protocol | Semi-trusted (path policy enforced) |
| ffmpeg | External process | Spawned for audio conversion; killed on cancellation | Trusted (system-installed binary) |
| Whisper.net + libwhisper | In-process native library | Loaded once per run; model loaded from local file | Trusted (vendored native runtime) |
| Local File System | Storage | All I/O: config, input audio, intermediate WAV, models, transcripts | Trusted (local disk) |
| VoxFlow.Core | .NET 9 shared library | Shared transcription services consumed by all hosts via DI | Trusted (same codebase) |
| VoxFlow.McpServer | .NET 9 console process | Separate MCP host injecting Core interfaces directly | Trusted (same codebase) |
| VoxFlow.Desktop | .NET 9 MAUI Blazor Hybrid | macOS desktop host injecting Core interfaces via DI | Trusted (same codebase) |

## Trust Boundaries

There is exactly one trust boundary: **the local machine**.

All actors and systems operate within this boundary. The application makes no network calls during transcription. Model download (a one-time operation) is the only network-touching behavior, and it writes to a local file that is validated before use.

The MCP server introduces a **semi-trusted boundary** between AI clients and the application core. File paths provided by AI clients are validated by `PathPolicy` against configurable allowed input/output root directories before any file system access occurs.

```
┌──────────────────────────────────────────────────────────────────┐
│                         Local Machine                            │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                  VoxFlow.Core (shared library)             │  │
│  │  Configuration → Validation → Pipeline → Output            │  │
│  │  ITranscriptionService, IValidationService, etc.           │  │
│  │                         ↕                                  │  │
│  │                   Whisper.net                               │  │
│  └────────────────────────────────────────────────────────────┘  │
│       ↑ (DI)              ↑ (DI)               ↑ (DI)           │
│  ┌──────────┐    ┌──────────────────┐    ┌───────────────┐      │
│  │ VoxFlow  │    │  VoxFlow.McpServer│    │ VoxFlow       │      │
│  │  .Cli    │    │  PathPolicy →     │    │  .Desktop     │      │
│  │          │    │  Core interfaces  │    │  Blazor Hybrid│      │
│  │ Operator │    │  ↕ stdio MCP      │    │  macOS UI     │      │
│  └──────────┘    │  AI Client        │    └───────────────┘      │
│                  └──────────────────┘                            │
│           ↕                        ↕                             │
│      ┌─────────┐          ┌──────────────┐                       │
│      │ ffmpeg  │          │  File System  │                       │
│      └─────────┘          └──────────────┘                       │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
               │
               │ (one-time model download only)
               ↓
        ┌──────────────┐
        │   Internet   │
        └──────────────┘
```

## Data Flow Summary

| Data | Source | Destination | Format | Notes |
|------|--------|-------------|--------|-------|
| Configuration | `appsettings.json` / env var | TranscriptionOptions | JSON | Loaded once at startup, immutable after |
| Input audio | Local `.m4a` file(s) | AudioConversionService | Binary | Single file or batch directory |
| Intermediate audio | ffmpeg output | WavAudioLoader | PCM WAV (16kHz, mono) | Deleted after processing unless configured otherwise |
| Whisper model | Local `.bin` file | ModelService → WhisperFactory | GGML binary | Reused across files in batch mode |
| Raw segments | Whisper inference | TranscriptionFilter | In-memory SegmentData | Timestamped text with probability scores |
| Filtered segments | TranscriptionFilter | OutputWriter | In-memory FilteredSegment | Accepted segments only |
| Transcript | OutputWriter | Local `.txt` file | UTF-8 text | `{start}->{end}: {text}` per line |
| Batch summary | BatchSummaryWriter | Local `.txt` file | UTF-8 text | Per-file status report |

## Data Flow Summary (MCP Server)

| Data | Source | Destination | Format | Notes |
|------|--------|-------------|--------|-------|
| MCP tool invocation | AI Client (stdin) | VoxFlow.McpServer | JSON-RPC | Tool name + arguments |
| MCP tool result | VoxFlow.McpServer (stdout) | AI Client | JSON-RPC | Structured JSON response |
| Diagnostic logs | VoxFlow.McpServer | stderr | Text | Console.SetOut(Console.Error) protects stdout |
| Path validation | MCP tool arguments | PathPolicy | String | Validated against allowed roots before file access |

## Data Flow Summary (Desktop App)

| Data | Source | Destination | Format | Notes |
|------|--------|-------------|--------|-------|
| File selection | User (file picker / drag-and-drop) | VoxFlow.Desktop | File path | macOS file system dialog |
| Progress updates | VoxFlow.Core (IProgress&lt;ProgressUpdate&gt;) | Blazor UI | In-memory | Host-agnostic progress reporting |
| Transcription result | VoxFlow.Core | Result screen | In-memory | Displayed in Blazor page |
| Settings | VoxFlow.Desktop | VoxFlow.Core | Configuration | Loaded at startup, passed to Core services |

## What Is Deliberately Excluded

The system context has no:

- **Network services** — No REST APIs, no message queues, no cloud storage. This is a design choice, not a limitation.
- **Database** — File system is the only persistence layer. For a local transcription tool, this is the right abstraction.
- **HTTP/SSE MCP transport** — The MCP server uses stdio only. HTTP transport would introduce network surface area that conflicts with the local-only principle.
