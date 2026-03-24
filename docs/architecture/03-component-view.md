# Component View

> C4 Level 3 — Detailed component responsibilities, interfaces, and data types.

## Component Diagram

```mermaid
flowchart LR
    subgraph Core["VoxFlow.Core (shared library)"]
        iTranscription["ITranscriptionService"]
        iValidation["IValidationService"]
        iConfig["IConfigurationService"]
        iBatch["IBatchTranscriptionService"]
        iReader["ITranscriptReader"]
        addcore["AddVoxFlowCore()"]

        config["TranscriptionOptions"]
        startup["StartupValidationService"]
        convert["AudioConversionService"]
        modelsvc["ModelService"]
        loader["WavAudioLoader"]
        select["LanguageSelectionService"]
        filter["TranscriptionFilter"]
        output["OutputWriter"]
        discovery["FileDiscoveryService"]
        summary["BatchSummaryWriter"]
    end

    subgraph Cli["VoxFlow.Cli"]
        cli_program["Program.cs"]
        cli_progress["ConsoleProgressService"]
    end

    subgraph Mcp["VoxFlow.McpServer"]
        mcp_program["Program.cs"]
        mcp_tools["WhisperMcpTools"]
        mcp_pathpolicy["PathPolicy"]
    end

    subgraph Desktop["VoxFlow.Desktop"]
        desktop_vm["AppViewModel"]
        desktop_pages["Blazor Pages"]
    end

    subgraph External["External Dependencies"]
        ffmpeg["ffmpeg"]
        whisper["Whisper.net + libwhisper"]
        files["Local File System"]
    end

    cli_program -->|DI| addcore
    mcp_program -->|DI| addcore
    desktop_vm -->|DI| addcore

    cli_program --> iTranscription
    cli_program --> iValidation
    mcp_tools --> iTranscription
    mcp_tools --> iValidation
    mcp_tools --> mcp_pathpolicy
    desktop_vm --> iTranscription
    desktop_vm --> iValidation
    desktop_pages --> desktop_vm

    iTranscription --> convert
    iTranscription --> modelsvc
    iTranscription --> loader
    iTranscription --> select
    iTranscription --> output
    iValidation --> startup
    iBatch --> discovery
    iBatch --> summary
    select --> filter

    startup -.-> files
    startup -.-> ffmpeg
    startup -.-> whisper
    convert -.-> ffmpeg
    convert -.-> files
    modelsvc -.-> files
    modelsvc -.-> whisper
    loader -.-> files
    output -.-> files
    discovery -.-> files
    summary -.-> files
```

## Component Details

### Core Service Interfaces

**File:** `VoxFlow.Core/Interfaces/`

**Responsibility:** Define the contracts that all host projects use to access transcription functionality via dependency injection.

| Interface | Responsibility |
|-----------|---------------|
| `ITranscriptionService` | Orchestrate single-file transcription pipeline (convert, model, load, infer, filter, write) |
| `IValidationService` | Run preflight checks and return structured validation reports |
| `IConfigurationService` | Load and provide immutable runtime configuration |
| `IBatchTranscriptionService` | Orchestrate batch file processing with error isolation and summary |
| `ITranscriptReader` | Read previously produced transcript files |

---

### AddVoxFlowCore (DI Registration)

**File:** `VoxFlow.Core/DependencyInjection/ServiceCollectionExtensions.cs`

**Responsibility:** Single entry point for registering all Core services in any host's DI container.

**Key behaviors:**
- Registers all service interfaces with their implementations
- Configures TranscriptionOptions from configuration
- Ensures consistent service lifetimes across hosts
- Called by CLI, MCP Server, and Desktop hosts identically

---

### Program — CLI Host (Orchestrator)

**File:** `VoxFlow.Cli/Program.cs`

**Responsibility:** Thin CLI entry point. Sets up DI via `AddVoxFlowCore()`, manages cancellation (Ctrl+C → CancellationTokenSource), and maps outcomes to exit codes.

**Key behaviors:**
- Registers Core services and console-specific progress reporting
- Delegates to `ITranscriptionService` or `IBatchTranscriptionService` via DI
- Provides `ConsoleProgressService` as the `IProgress<ProgressUpdate>` implementation

**Exit codes:** 0 (success), 1 (failure), 130 (cancelled)

---

### TranscriptionOptions (Configuration)

**File:** `Configuration/TranscriptionOptions.cs`

**Responsibility:** Load, validate, and normalize all runtime settings into a sealed immutable object.

**Key behaviors:**
- Loads from `appsettings.json` or path specified by `TRANSCRIPTION_SETTINGS_PATH` environment variable
- Validates numeric ranges, probabilities, language codes, and path existence
- Exposes 45+ properties covering all runtime behavior
- Provides `GetSupportedLanguageSummary()` for human-readable language display

**Design note:** The class is sealed with read-only properties. Once loaded, configuration cannot be modified. This eliminates an entire class of bugs where runtime behavior changes unexpectedly.

**Related types:**
- `SupportedLanguage` (record) — language code, display name, and priority
- Internal JSON deserialization classes for the appsettings schema

---

### StartupValidationService (Preflight Checks)

**File:** `Services/StartupValidationService.cs`

**Responsibility:** Run configurable preflight checks and produce a structured validation report.

**Checks performed (15+):**

| Check | Mode | What it validates |
|-------|------|-------------------|
| Settings file | Both | Configuration file exists |
| Input file | Single | Input .m4a exists |
| Output directory | Single | Output directory exists and is writable |
| ffmpeg availability | Both | `ffmpeg -version` succeeds |
| Model type | Both | Configured model type is a valid GGML type |
| Model directory | Both | Model directory exists and is writable |
| Model file | Both | Model file loads without error |
| Whisper runtime | Both | Native library loads successfully |
| Language support | Both | Configured languages are valid Whisper language codes |
| Batch input directory | Batch | Input directory exists |
| Batch output directory | Batch | Output directory exists and is writable |
| Batch temp directory | Batch | Temp directory exists and is writable |
| Batch file pattern | Batch | Pattern is non-empty |

**Related types:**
- `StartupValidationReport` (sealed class) — aggregated check results with overall outcome
- `StartupCheckResult` (record) — name, status, optional message
- `StartupCheckStatus` (enum) — Passed, Warning, Failed, Skipped
- `StartupValidationConsoleReporter` (static class) — ANSI-colored console output

---

### AudioConversionService (Audio Preprocessing)

**File:** `Audio/AudioConversionService.cs`

**Responsibility:** Invoke ffmpeg to convert `.m4a` input to filtered mono 16kHz WAV.

**Key behaviors:**
- Validates input file existence before conversion
- Validates ffmpeg availability (separate from startup validation — can be called independently)
- Builds ffmpeg command line from configuration (audio filters, codec settings)
- Manages ffmpeg child process lifecycle including cancellation (kills process on token cancellation)
- Two overloads: single-file (fixed output path) and batch (per-file temp path)

**Design note:** This is the only module that spawns external processes. Process management complexity is contained here rather than scattered.

**Related types:**
- `ProcessRunResult` (record) — exit code, stdout, stderr from ffmpeg

---

### WavAudioLoader (Audio Parsing)

**File:** `Audio/WavAudioLoader.cs`

**Responsibility:** Parse WAV files into normalized float sample arrays suitable for Whisper inference.

**Key behaviors:**
- Validates RIFF/WAVE header structure
- Supports multiple PCM bit depths: 8-bit, 16-bit, 24-bit, 32-bit
- Supports IEEE float format
- Normalizes all formats to float32 in [-1.0, 1.0] range
- Chunk-based parsing (navigates fmt and data chunks)

**Design note:** This module handles the impedance mismatch between ffmpeg's WAV output and Whisper.net's expected input format. It is tested with generated WAV fixtures covering each supported bit depth.

---

### ModelService (Model Management)

**File:** `Services/ModelService.cs`

**Responsibility:** Load Whisper GGML models with reuse-first behavior.

**Key behaviors:**
- Attempts to reuse existing model file first
- Downloads model only when file is missing, empty, or corrupt
- Uses atomic file operations (write to temp, then move) to prevent corrupt partial downloads
- Returns a `WhisperFactory` ready for processor creation

**Reuse-first strategy:**
```
Model file exists and loads? → Reuse
Model file exists but fails? → Re-download
Model file missing?          → Download
```

---

### LanguageSelectionService (Inference + Scoring)

**File:** `Services/LanguageSelectionService.cs`

**Responsibility:** Run Whisper inference for configured languages and select the best candidate.

**Single-language flow:**
- Forces the configured language directly — no comparison needed

**Multi-language flow:**
- Runs one inference pass per configured language
- Scores each candidate using duration-weighted segment probability
- Selects winner with configurable ambiguity handling (reject or warn)

**Scoring formula:** Each segment's probability is weighted by its duration relative to total audio duration. This prevents a single long low-confidence segment from dominating the score.

**Related types:**
- `CandidateTranscriptionResult` (record) — language, segments, score
- `LanguageSelectionDecision` (record) — winning candidate + optional warning
- `UnsupportedLanguageException` — controlled failure for invalid language codes

---

### TranscriptionFilter (Post-Processing)

**File:** `Processing/TranscriptionFilter.cs`

**Responsibility:** Accept or reject raw Whisper segments based on configurable rules.

**Filtering stages (applied in order):**

| Stage | What it catches |
|-------|----------------|
| Empty text | Blank segments |
| Non-speech markers | Configurable list (e.g., `[BLANK_AUDIO]`, `(silence)`) |
| Bracketed placeholders | Stage directions like `[music]`, `[applause]` |
| Low probability | Below configurable threshold |
| Low-information long segments | Long duration + low average probability |
| Suspicious non-speech | Text with no letters or digits (punctuation-only) |
| Repetitive loops | Short phrases repeated multiple times (hallucination pattern) |

**Design note:** Each filter stage returns a specific `SegmentSkipReason`, enabling diagnostic logging that explains exactly why a segment was rejected. This is critical for debugging Whisper hallucination behavior.

**Related types:**
- `CandidateFilteringResult` (record) — accepted + skipped segments
- `FilteredSegment` (record) — accepted segment with timestamp and text
- `SkippedSegment` (record) — rejected segment with reason
- `SegmentSkipReason` (enum) — Empty, NoiseMarker, BracketedPlaceholder, LowProbability, LowInformationLong, SuspiciousNonSpeech, RepetitiveLoop

---

### ConsoleProgressService (Presentation)

**File:** `Services/ConsoleProgressService.cs`

**Responsibility:** Render real-time progress during transcription.

**Key behaviors:**
- Animated spinner with percentage completion
- Elapsed time tracking
- Batch-level context (`[File X/Y]` prefix)
- Detects interactive vs. redirected console (disables ANSI in pipes)
- Thread-safe rendering via lock

---

### OutputWriter (File Output)

**File:** `Services/OutputWriter.cs`

**Responsibility:** Write accepted transcript segments to a UTF-8 text file.

**Output format:** `{start:TimeSpan}->{end:TimeSpan}: {text}\n`

**Design note:** `BuildOutputText()` is separated from `WriteAsync()` to enable unit testing of output formatting without file I/O.

---

### FileDiscoveryService (Batch Input)

**File:** `Services/FileDiscoveryService.cs`

**Responsibility:** Discover input files for batch processing.

**Key behaviors:**
- Scans configured input directory with file pattern (e.g., `*.m4a`)
- Computes output path and temp WAV path for each file
- Alphabetical sorting for deterministic processing order
- Filters empty files (marked as Skipped)

**Related types:**
- `DiscoveredFile` (record) — input/output/temp paths, status
- `DiscoveryStatus` (enum) — Ready, Skipped

---

### BatchSummaryWriter (Batch Reporting)

**File:** `Services/BatchSummaryWriter.cs`

**Responsibility:** Generate a human-readable summary of batch processing results.

**Output includes:** total/succeeded/failed/skipped counts, total duration, and per-file status with error details.

**Related types:**
- `FileProcessingResult` (record) — file path, status, language, duration, error
- `FileProcessingStatus` (enum) — Success, Failed, Skipped

---

## MCP Server Components

> These components live in the `VoxFlow.McpServer` project — a separate .NET 9 console application that injects `VoxFlow.Core` interfaces directly via DI.

### PathPolicy (Security)

**File:** `Security/PathPolicy.cs`

**Responsibility:** Enforce allowed input/output root directories for file paths provided by AI clients.

**Key behaviors:**
- Validates paths are absolute (when `requireAbsolutePaths` is configured)
- Rejects path traversal patterns (`../`, `..\\`)
- Normalizes and checks paths against configured allowed root directories
- Provides `SanitizePath()` for safe error messages (no raw user paths in errors)

---

### WhisperMcpTools (MCP Tools)

**File:** `VoxFlow.McpServer/Tools/WhisperMcpTools.cs`

**Responsibility:** Expose VoxFlow transcription capabilities as MCP tools discoverable by AI clients.

**6 tools:** `validate_environment`, `transcribe_file`, `transcribe_batch`, `get_supported_languages`, `inspect_model`, `read_transcript`

Each tool validates paths via `IPathPolicy`, delegates to the appropriate Core service interface, and returns JSON-serialized results.

---

### WhisperMcpPrompts (MCP Prompts)

**File:** `VoxFlow.McpServer/Prompts/WhisperMcpPrompts.cs`

**Responsibility:** Provide guided workflow instructions for AI clients using VoxFlow.

**4 prompts:** `transcribe-local-audio`, `batch-transcribe-folder`, `diagnose-transcription-setup`, `inspect-last-transcript`

---

### WhisperMcpResourceTools (MCP Resource Tools)

**File:** `VoxFlow.McpServer/Resources/WhisperMcpResources.cs`

**Responsibility:** Expose read-only VoxFlow configuration as an MCP tool.

**1 tool:** `get_effective_config` — returns the resolved configuration snapshot as JSON.

---

### McpOptions (MCP Configuration)

**File:** `VoxFlow.McpServer/Configuration/McpOptions.cs`

**Responsibility:** MCP-specific configuration loaded from the `mcp` section of `appsettings.json`.

**Key settings:** server name/version, allowed input/output roots, batch limits, path policy, resource/prompt toggles, logging.

---

## Desktop Components

> These components live in the `VoxFlow.Desktop` project — a .NET 9 MAUI Blazor Hybrid macOS application that uses `VoxFlow.Core` via DI.

### AppViewModel (Application State)

**Responsibility:** Manages application state and mediates between Blazor pages and Core service interfaces. Implements `IProgress<ProgressUpdate>` to bridge Core progress reporting to the Blazor UI.

**Key behaviors:**
- Injects Core service interfaces via constructor DI
- Manages navigation flow between screens (the current Blazor page is the application state)
- Translates `ProgressUpdate` events into UI-bindable properties
- Handles file selection from picker and drag-and-drop

---

### Blazor Pages (UI Screens)

**Responsibility:** Render the visual transcription workflow as Blazor components within the MAUI native shell.

| Page | Responsibility |
|------|---------------|
| Welcome / First Run | Display dependency validation status; trigger model download |
| File Selection | File picker and drag-and-drop for `.m4a` input |
| Transcription | Real-time progress display during pipeline execution |
| Result | Transcript review with copy and export |
| Settings | Model, language, and path configuration |

**Design note:** Navigation follows a contextual flow model — the screen IS the state. There is no separate state machine abstraction. The current Blazor page represents the current application state, and navigation between pages drives the workflow forward. Dark theme is applied consistently across all pages.
