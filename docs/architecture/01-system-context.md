# System Context View

> C4 Level 1 — How VoxFlow fits into its environment.

## Context Diagram

```mermaid
C4Context
    title System Context — VoxFlow

    Person(operator, "Operator", "Developer or user running local transcription")

    System(app, "VoxFlow", ".NET 9 console application<br/>Orchestrates fully local audio transcription")

    System_Ext(ffmpeg, "ffmpeg", "External process<br/>Audio format conversion and filtering")
    System_Ext(whisper_runtime, "Whisper.net + libwhisper", "In-process native library<br/>Speech-to-text inference via GGML models")
    SystemDb_Ext(filesystem, "Local File System", "Audio inputs, GGML models, config, transcript outputs")

    Rel(operator, app, "Runs via CLI", "dotnet run / compiled binary")
    Rel(app, ffmpeg, "Spawns child process", ".m4a → 16kHz mono .wav")
    Rel(app, whisper_runtime, "P/Invoke via Whisper.net", "Load model, run inference")
    Rel(app, filesystem, "Read/Write", "Config, audio, models, transcripts")
```

## Actors and External Systems

| Actor / System | Type | Interaction | Trust Level |
|---------------|------|-------------|-------------|
| Operator | Human | Configures `appsettings.json`, invokes CLI, reads output | Full trust (local user) |
| ffmpeg | External process | Spawned for audio conversion; killed on cancellation | Trusted (system-installed binary) |
| Whisper.net + libwhisper | In-process native library | Loaded once per run; model loaded from local file | Trusted (vendored native runtime) |
| Local File System | Storage | All I/O: config, input audio, intermediate WAV, models, transcripts | Trusted (local disk) |

## Trust Boundaries

There is exactly one trust boundary: **the local machine**.

All actors and systems operate within this boundary. The application makes no network calls during transcription. Model download (a one-time operation) is the only network-touching behavior, and it writes to a local file that is validated before use.

```
┌─────────────────────────────────────────────────────────────┐
│                     Local Machine                           │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Application Process                     │   │
│  │  Configuration → Validation → Pipeline → Output      │   │
│  │                                    ↕                  │   │
│  │                              Whisper.net              │   │
│  └──────────────────────────────────────────────────────┘   │
│           ↕                        ↕                        │
│      ┌─────────┐          ┌──────────────┐                  │
│      │ ffmpeg  │          │  File System  │                  │
│      └─────────┘          └──────────────┘                  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
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

## What Is Deliberately Excluded

The system context has no:

- **Network services** — No REST APIs, no message queues, no cloud storage. This is a design choice, not a limitation.
- **Database** — File system is the only persistence layer. For a local transcription tool, this is the right abstraction.
- **Other applications** — The tool is standalone. The [ROADMAP](../product/ROADMAP.md) describes a future MCP server integration, but that would be a separate process with a shared application core, not a modification to this context.
