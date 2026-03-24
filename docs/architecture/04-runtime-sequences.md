# Runtime Sequences

> How the application behaves at runtime — sequence diagrams for both processing modes.

## Single-File Mode (CLI)

```mermaid
sequenceDiagram
    participant User
    participant Program as Program.cs (CLI Host)
    participant DI as AddVoxFlowCore()
    participant ITranscription as ITranscriptionService
    participant IValidation as IValidationService
    participant Progress as ConsoleProgressService
    participant Core as Core Pipeline

    User->>Program: dotnet run
    Program->>DI: Register Core services
    DI-->>Program: ServiceProvider ready

    Program->>IValidation: ValidateAsync(options)
    alt Validation failed
        IValidation-->>Program: Report with failures
        Program-->>User: Exit 1 with diagnostics
    end
    IValidation-->>Program: Report (passed/warnings)

    Program->>ITranscription: TranscribeAsync(inputPath, progress)
    ITranscription->>Core: Convert → Model → Load → Infer → Filter → Write
    Core->>Progress: IProgress<ProgressUpdate> callbacks
    Progress->>Progress: Render ANSI progress bar
    Core-->>ITranscription: Pipeline result

    ITranscription-->>Program: Transcription result

    alt No winning candidate
        Program-->>User: Exit 1
    end

    Program-->>User: Exit 0
```

## Batch Mode

```mermaid
sequenceDiagram
    participant User
    participant Program
    participant Config as TranscriptionOptions
    participant Validation as StartupValidationService
    participant Model as ModelService
    participant Discovery as FileDiscoveryService
    participant FFmpeg as AudioConversionService
    participant Loader as WavAudioLoader
    participant Lang as LanguageSelectionService
    participant Writer as OutputWriter
    participant Summary as BatchSummaryWriter

    User->>Program: dotnet run (processingMode=batch)
    Program->>Config: Load()
    Config-->>Program: Immutable options (batch mode)

    Program->>Validation: ValidateAsync(options)
    alt Validation failed
        Validation-->>Program: Report with failures
        Program-->>User: Exit 1 with diagnostics
    end
    Validation-->>Program: Report (passed/warnings)

    Note over Program,Model: Model loaded ONCE before file loop
    Program->>Model: CreateFactoryAsync(options)
    Model-->>Program: WhisperFactory (shared)

    Program->>Discovery: DiscoverInputFiles(options)
    Discovery-->>Program: List<DiscoveredFile>

    loop For each discovered file
        alt File status = Skipped
            Program->>Program: Record skip result
        else File status = Ready
            Program->>FFmpeg: ConvertToWavAsync(input, tempWav)
            FFmpeg-->>Program: Temp WAV written

            Program->>Loader: LoadSamplesAsync(tempWav)
            Loader-->>Program: float[] samples

            Program->>Lang: SelectBestCandidateAsync(factory, samples, options)
            Lang-->>Program: LanguageSelectionDecision

            Program->>Writer: WriteAsync(segments, outputPath)
            Writer-->>Program: Per-file transcript written

            Program->>Program: CleanupTempWav(tempWav)
            Program->>Program: Record success result
        end

        alt Error during file processing
            Program->>Program: Record error result
            alt stopOnFirstError = true
                Program->>Program: Break loop
            end
        end
    end

    Program->>Summary: WriteAsync(results)
    Summary-->>Program: Batch summary written

    Program-->>User: Exit with batch status
```

## Cancellation Flow

```mermaid
sequenceDiagram
    participant User
    participant Program
    participant CTS as CancellationTokenSource
    participant FFmpeg as AudioConversionService
    participant Lang as LanguageSelectionService

    User->>Program: Ctrl+C
    Program->>CTS: Cancel()

    alt During ffmpeg conversion
        CTS-->>FFmpeg: Token cancelled
        FFmpeg->>FFmpeg: Kill ffmpeg child process
        FFmpeg-->>Program: OperationCanceledException
    end

    alt During Whisper inference
        CTS-->>Lang: Token cancelled
        Lang-->>Program: OperationCanceledException
    end

    Program-->>User: Exit 130 (cancelled)
```

## MCP Server — Tool Invocation

```mermaid
sequenceDiagram
    participant AIClient as AI Client
    participant McpServer as MCP Server (stdio)
    participant PathPolicy
    participant ITranscription as ITranscriptionService (Core)
    participant Pipeline as VoxFlow.Core Pipeline

    AIClient->>McpServer: MCP tool call (e.g., transcribe_file)
    McpServer->>McpServer: Deserialize JSON-RPC request

    McpServer->>PathPolicy: ValidateInputPath(inputPath)
    alt Path validation fails
        PathPolicy-->>McpServer: Exception (outside allowed roots)
        McpServer-->>AIClient: JSON error response
    end
    PathPolicy-->>McpServer: Path accepted

    opt Output path provided
        McpServer->>PathPolicy: ValidateOutputPath(outputPath)
        PathPolicy-->>McpServer: Path accepted
    end

    McpServer->>ITranscription: TranscribeAsync(request)
    ITranscription->>Pipeline: Convert → Model → Load → Infer → Filter → Write
    Pipeline-->>ITranscription: Pipeline result
    ITranscription-->>McpServer: Transcription result

    McpServer->>McpServer: Serialize to JSON
    McpServer-->>AIClient: MCP tool result (JSON-RPC response)
```

## MCP Server — Prompt-Guided Workflow

```mermaid
sequenceDiagram
    participant AIClient as AI Client
    participant McpServer as MCP Server (stdio)

    AIClient->>McpServer: MCP prompt request (e.g., transcribe-local-audio)
    McpServer-->>AIClient: Workflow instructions (step-by-step guide)

    Note over AIClient: AI client follows the prompt instructions

    AIClient->>McpServer: validate_environment tool call
    McpServer-->>AIClient: Validation results

    AIClient->>McpServer: transcribe_file tool call
    McpServer-->>AIClient: Transcription results

    AIClient->>McpServer: read_transcript tool call
    McpServer-->>AIClient: Transcript content
```

## Desktop — First-Run Validation

```mermaid
sequenceDiagram
    participant User as Desktop User
    participant Desktop as VoxFlow.Desktop
    participant VM as AppViewModel
    participant IValidation as IValidationService (Core)
    participant IConfig as IConfigurationService (Core)

    User->>Desktop: Launch app
    Desktop->>VM: Initialize (DI via AddVoxFlowCore)

    VM->>IConfig: LoadConfiguration()
    IConfig-->>VM: TranscriptionOptions

    VM->>IValidation: ValidateAsync(options)
    IValidation-->>VM: Validation report

    alt All checks passed
        VM->>Desktop: Navigate to File Selection
    else Critical failures
        VM->>Desktop: Show Welcome/First-Run screen
        Desktop->>User: Display dependency status (ffmpeg, model, etc.)

        opt Model missing
            User->>Desktop: Confirm model download
            Desktop->>VM: DownloadModelAsync()
            VM->>VM: IProgress<ProgressUpdate> → UI progress bar
            VM-->>Desktop: Model downloaded
        end

        User->>Desktop: Re-run validation
        VM->>IValidation: ValidateAsync(options)
        IValidation-->>VM: Updated report
    end
```

## Desktop — Single-File Transcription

```mermaid
sequenceDiagram
    participant User as Desktop User
    participant Pages as Blazor Pages
    participant VM as AppViewModel
    participant ITranscription as ITranscriptionService (Core)
    participant Core as Core Pipeline

    User->>Pages: Select file (picker or drag-and-drop)
    Pages->>VM: SetInputFile(path)
    VM-->>Pages: Navigate to Transcription screen

    Pages->>VM: StartTranscription()
    VM->>ITranscription: TranscribeAsync(inputPath, progress)
    ITranscription->>Core: Convert → Model → Load → Infer → Filter → Write

    loop During transcription
        Core->>VM: IProgress<ProgressUpdate> callback
        VM->>Pages: Update progress display (percentage, elapsed, activity)
    end

    Core-->>ITranscription: Pipeline result
    ITranscription-->>VM: Transcription result

    VM-->>Pages: Navigate to Result screen
    Pages->>User: Display transcript with copy/export options
```

## Key Observations

**Model reuse in batch mode.** The Whisper model is loaded once before the file loop begins. This is a deliberate choice (ADR-010, ADR-011) — loading a GGML model is expensive, and native runtime teardown on macOS has shown instability. Sharing the factory across files trades theoretical resource isolation for practical stability.

**Sequential file processing.** Files are processed one at a time within the loop. There is no parallelism. This keeps memory usage predictable, avoids native runtime contention, and simplifies error isolation (see ADR-011).

**Error isolation.** Each file in the batch loop has its own try/catch. A failure in one file records the error and continues to the next (unless `stopOnFirstError` is configured). The summary report at the end provides a clear picture of what succeeded and what failed.

**Temp WAV cleanup.** Intermediate WAV files are deleted after each file completes processing. This bounds disk usage during long batch runs. The `keepIntermediateFiles` option exists for debugging.

**MCP stdout protection.** The MCP server redirects `Console.SetOut(Console.Error)` at startup. This ensures that any diagnostic writes from VoxFlow services go to stderr, keeping the stdout channel clean for MCP JSON-RPC protocol frames.

**MCP path validation.** Every file path from an MCP tool argument passes through `PathPolicy` before reaching the Core service interfaces. This is a hard security boundary — paths outside configured allowed roots are rejected with an error response, never reaching the file system.

**Desktop contextual flow.** The Desktop app uses a contextual navigation model where the current Blazor page represents the application state. There is no separate state machine — navigating to a page IS transitioning to that state. This simplifies the mental model and keeps the UI code straightforward.

**Host-agnostic progress.** Core services report progress via `IProgress<ProgressUpdate>`. The CLI host renders this as an ANSI progress bar, the Desktop host renders it as a Blazor UI update, and the MCP server suppresses it. This decoupling means Core services have no knowledge of how progress is displayed.
