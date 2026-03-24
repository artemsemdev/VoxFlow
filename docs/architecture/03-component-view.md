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
        validation["ValidationService"]
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
        cli_progress["CliProgressHandler"]
    end

    subgraph Mcp["VoxFlow.McpServer"]
        mcp_program["Program.cs"]
        mcp_tools["WhisperMcpTools"]
        mcp_pathpolicy["PathPolicy"]
    end

    subgraph Desktop["VoxFlow.Desktop"]
        desktop_routes["Routes.razor"]
        desktop_layout["MainLayout.razor"]
        desktop_vm["AppViewModel"]
        desktop_config["DesktopConfigurationService"]
        desktop_bridge["DesktopCliTranscriptionService"]
        desktop_pages["ReadyView / RunningView / FailedView / CompleteView / DropZone"]
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
    desktop_routes --> desktop_vm
    desktop_layout --> desktop_pages
    desktop_vm --> iValidation
    desktop_vm --> iConfig
    desktop_vm --> iTranscription
    desktop_vm --> desktop_bridge
    desktop_vm --> desktop_config
    desktop_pages --> desktop_vm

    iTranscription --> convert
    iTranscription --> modelsvc
    iTranscription --> loader
    iTranscription --> select
    iTranscription --> output
    iValidation --> validation
    iBatch --> discovery
    iBatch --> summary
    select --> filter

    validation -.-> files
    validation -.-> ffmpeg
    validation -.-> whisper
    convert -.-> ffmpeg
    convert -.-> files
    modelsvc -.-> files
    modelsvc -.-> whisper
    loader -.-> files
    output -.-> files
    discovery -.-> files
    summary -.-> files
    desktop_config -.-> files
    desktop_bridge --> cli_program
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
- Called by CLI, MCP Server, and Desktop as the shared DI baseline; Desktop then adds its own configuration and bridge services

---

### Program — CLI Host (Orchestrator)

**File:** `VoxFlow.Cli/Program.cs`

**Responsibility:** Thin CLI entry point. Sets up DI via `AddVoxFlowCore()`, manages cancellation (Ctrl+C → CancellationTokenSource), and maps outcomes to exit codes.

**Key behaviors:**
- Registers Core services and console-specific progress reporting
- Delegates to `ITranscriptionService` or `IBatchTranscriptionService` via DI
- Provides `CliProgressHandler` as the `IProgress<ProgressUpdate>` implementation

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

### ValidationService (Preflight Checks)

**File:** `Services/ValidationService.cs`

**Responsibility:** Run configurable preflight checks and produce a structured validation report.

**Checks performed (configurable by `startupValidation`):**

| Check | Mode | What it validates |
|-------|------|-------------------|
| Settings file | Both | Resolved configuration path |
| Input file | Single | Input .m4a exists |
| Output directory | Single | Output directory exists and is writable |
| ffmpeg availability | Both | `ffmpeg -version` succeeds |
| Model type | Both | Configured model type is a valid GGML type |
| Model directory | Both | Model directory exists and is writable |
| Model file state | Both | Existing model can be reused, or a download is needed |
| Whisper runtime | Both | Native library loads successfully |
| Language support | Both | Configured languages are valid Whisper language codes |
| Batch input directory | Batch | Input directory exists |
| Batch output directory | Batch | Output directory exists and is writable |
| Batch temp directory | Batch | Temp directory exists and is writable |
| Batch file pattern | Batch | Pattern is non-empty |

**Related types:**
- `ValidationResult` (record) — aggregated check results with overall outcome
- `ValidationCheck` (record) — name, status, details
- `ValidationCheckStatus` (enum) — Passed, Warning, Failed, Skipped
- `ConsoleValidationReporter` (static class) — ANSI-colored console output for CLI

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

**Design note:** Within `VoxFlow.Core`, this is the only module that spawns external processes. Desktop host code may additionally launch the local CLI bridge on Intel Mac Catalyst.

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

### CliProgressHandler (Presentation)

**File:** `VoxFlow.Cli/CliProgressHandler.cs`

**Responsibility:** Render real-time progress during transcription.

**Key behaviors:**
- Renders a single-line console progress prefix derived from `ProgressStage`
- Prints percentage completion and current message
- Writes a final newline on `Complete` or `Failed`
- Stays thin by consuming the host-agnostic `ProgressUpdate` type from Core

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

### DesktopConfigurationService (Desktop Config Composition)

**File:** `VoxFlow.Desktop/Configuration/DesktopConfigurationService.cs`

**Responsibility:** Build the Desktop runtime configuration from bundled defaults, user overrides, and optional explicit overrides.

**Key behaviors:**
- Merges bundled `appsettings.json` with `~/Library/Application Support/VoxFlow/appsettings.json`
- Normalizes Desktop paths into `~/Library/Application Support/VoxFlow/` and `~/Documents/VoxFlow/`
- Writes temporary merged snapshots for startup and CLI-bridge execution
- Applies Intel bridge compatibility overrides during startup validation only

---

### DesktopCliTranscriptionService (Intel Compatibility Bridge)

**File:** `VoxFlow.Desktop/Services/DesktopCliTranscriptionService.cs`

**Responsibility:** Replace the default `ITranscriptionService` on Intel Mac Catalyst and execute transcription through the local CLI host.

**Key behaviors:**
- Writes a merged temporary config and injects the selected input path
- Launches `VoxFlow.Cli` via `dotnet exec` when a built CLI assembly exists, otherwise falls back to `dotnet run --project`
- Reports Desktop-friendly progress such as `Running CLI transcription pipeline...`
- Parses CLI stdout/stderr for success metadata and failure messages
- Reads the resulting transcript file back into the Desktop UI

---

### AppViewModel (Application State)

**File:** `VoxFlow.Desktop/ViewModels/AppViewModel.cs`

**Responsibility:** Manage Desktop UI state and mediate between Blazor views and the configured transcription implementation.

**Key behaviors:**
- Initializes the app by loading configuration and running startup validation
- Owns the UI state machine: `Ready`, `Running`, `Failed`, `Complete`
- Stores the last selected file for retry
- Builds `BlockingValidationMessage` from failed startup checks
- Accepts `ProgressUpdate` events through `BlazorProgressHandler` and exposes them to the UI

---

### Blazor Pages (UI Screens)

**Responsibility:** Render the visual transcription workflow as Blazor components within the MAUI native shell.

| Page | Responsibility |
|------|---------------|
| Routes | Startup initialization surface; shows a startup-error retry view when initialization throws |
| ReadyView | Ready screen with validation banner and file selection entry points |
| RunningView | Real-time progress during transcription |
| FailedView | Error message plus retry / choose-different-file actions |
| CompleteView | Transcript preview with open-folder and copy-to-clipboard actions |
| DropZone | Shared browse / drag-and-drop entry surface used by `ReadyView` |

**Design note:** The Desktop shell is state-driven, not route-driven. `Routes.razor` handles startup initialization and retry. Once initialized, `MainLayout.razor` switches between `ReadyView`, `RunningView`, `FailedView`, and `CompleteView` based on `AppViewModel.CurrentState`.

**Current verification status:**

- `tests/VoxFlow.Desktop.Tests` exercises `Routes`, `MainLayout`, `ReadyView`, `RunningView`, `FailedView`, `CompleteView`, `DropZone`, and `AppViewModel` transitions in a headless renderer.
- `tests/VoxFlow.Desktop.UiTests` launches the built `.app`, drives the native Open dialog, and verifies the integrated `Ready -> Running -> Complete` path against the real Desktop shell.
- The current Desktop UI does not expose a settings editor; persistent overrides remain file-based in `~/Library/Application Support/VoxFlow/appsettings.json`.
- On Intel Mac Catalyst, the integrated UI path is exercised through the CLI bridge rather than in-process Whisper runtime loading.
