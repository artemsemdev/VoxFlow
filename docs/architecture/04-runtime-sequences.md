# Runtime Sequences

> How the application behaves at runtime across the supported hosts.

## Single-File Mode (CLI)

```mermaid
sequenceDiagram
    participant User
    participant Program as Program.cs (CLI Host)
    participant DI as AddVoxFlowCore()
    participant IConfig as IConfigurationService
    participant IValidation as IValidationService
    participant ITranscription as ITranscriptionService
    participant Progress as CliProgressHandler
    participant Core as Core Pipeline

    User->>Program: dotnet run
    Program->>DI: Register Core services
    DI-->>Program: ServiceProvider ready

    Program->>IConfig: LoadAsync()
    IConfig-->>Program: TranscriptionOptions

    Program->>IValidation: ValidateAsync(options)
    alt Validation failed
        IValidation-->>Program: ValidationResult (CanStart = false)
        Program-->>User: Exit 1 with diagnostics
    end
    IValidation-->>Program: ValidationResult

    Program->>ITranscription: TranscribeFileAsync(request, progress)
    ITranscription->>Core: Convert -> Model -> Load -> Infer -> Filter -> Write
    Core->>Progress: IProgress<ProgressUpdate> callbacks
    Progress->>Progress: Render console progress
    Core-->>ITranscription: TranscribeFileResult
    ITranscription-->>Program: Result

    alt Result.Success = false
        Program-->>User: Exit 1
    else Result.Success = true
        Program-->>User: Exit 0
    end
```

## Batch Mode (CLI)

```mermaid
sequenceDiagram
    participant User
    participant Program
    participant Config as IConfigurationService
    participant Validation as IValidationService
    participant Batch as IBatchTranscriptionService
    participant Core as Batch Pipeline

    User->>Program: dotnet run (processingMode=batch)
    Program->>Config: LoadAsync()
    Config-->>Program: Immutable options (batch mode)

    Program->>Validation: ValidateAsync(options)
    alt Validation failed
        Validation-->>Program: ValidationResult (CanStart = false)
        Program-->>User: Exit 1 with diagnostics
    end
    Validation-->>Program: ValidationResult

    Program->>Batch: TranscribeBatchAsync(request, progress)
    Batch->>Core: Discover -> Convert -> Load -> Infer -> Filter -> Write -> Summarize
    Core-->>Batch: BatchTranscribeResult
    Batch-->>Program: Result

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

    Program-->>User: Exit with cancellation message
```

## MCP Server — Tool Invocation

```mermaid
sequenceDiagram
    participant AIClient as AI Client
    participant McpServer as MCP Server (stdio)
    participant PathPolicy
    participant ITranscription as ITranscriptionService (Core)
    participant Pipeline as VoxFlow.Core Pipeline

    AIClient->>McpServer: MCP tool call (e.g. transcribe_file)
    McpServer->>McpServer: Deserialize JSON-RPC request

    McpServer->>PathPolicy: ValidateInputPath(inputPath)
    alt Path validation fails
        PathPolicy-->>McpServer: Exception
        McpServer-->>AIClient: JSON error response
    end
    PathPolicy-->>McpServer: Path accepted

    opt Output path provided
        McpServer->>PathPolicy: ValidateOutputPath(outputPath)
        PathPolicy-->>McpServer: Path accepted
    end

    McpServer->>ITranscription: TranscribeFileAsync(request)
    ITranscription->>Pipeline: Convert -> Model -> Load -> Infer -> Filter -> Write
    Pipeline-->>ITranscription: Result
    ITranscription-->>McpServer: Transcription result

    McpServer->>McpServer: Serialize JSON response
    McpServer-->>AIClient: MCP tool result
```

## Desktop — Startup and Validation

```mermaid
sequenceDiagram
    participant User as Desktop User
    participant Routes as Routes.razor
    participant VM as AppViewModel
    participant Config as DesktopConfigurationService
    participant IValidation as IValidationService
    participant Layout as MainLayout / ReadyView

    User->>Routes: Launch app
    Routes->>VM: InitializeAsync()
    VM->>Config: LoadAsync()
    Config->>Config: Merge bundled config + user overrides
    Config->>Config: Apply Intel startup overrides when CLI bridge is active
    Config-->>VM: TranscriptionOptions

    VM->>IValidation: ValidateAsync(options)
    IValidation-->>VM: ValidationResult

    alt Initialization throws
        VM-->>Routes: Exception
        Routes-->>User: Show startup error screen with Retry
    else Initialization succeeds
        VM-->>Layout: CurrentState = Ready
        alt ValidationResult.CanStart = false
            Layout-->>User: Show ReadyView warning banner and disable file selection
        else Validation passed or warnings only
            Layout-->>User: Show ReadyView with Browse Files / DropZone enabled
        end
    end
```

## Desktop — Single-File Transcription

```mermaid
sequenceDiagram
    participant User as Desktop User
    participant Ready as ReadyView / DropZone
    participant VM as AppViewModel
    participant ITranscription as ITranscriptionService
    participant Bridge as DesktopCliTranscriptionService
    participant CLI as VoxFlow.Cli
    participant Core as VoxFlow.Core Pipeline
    participant Result as FailedView / CompleteView

    User->>Ready: Select file (Browse Files or drag-and-drop)
    Ready->>VM: TranscribeFileAsync(path)
    VM->>VM: CurrentState = Running
    VM->>ITranscription: TranscribeFileAsync(request, progress)

    alt Apple Silicon / default Core path
        ITranscription->>Core: Convert -> Model -> Load -> Infer -> Filter -> Write
        loop During transcription
            Core->>VM: ProgressUpdate via BlazorProgressHandler
        end
        Core-->>ITranscription: TranscribeFileResult
    else Intel Mac Catalyst / CLI bridge
        ITranscription->>Bridge: TranscribeFileAsync(request, progress)
        Bridge->>Bridge: Write merged temp config with selected file
        Bridge->>VM: Report "Running CLI transcription pipeline..."
        Bridge->>CLI: dotnet exec/run VoxFlow.Cli
        CLI->>Core: Validate -> Convert -> Model -> Load -> Infer -> Filter -> Write
        Core-->>CLI: Transcript written
        CLI-->>Bridge: Exit code + stdout/stderr
        Bridge->>Bridge: Read transcript preview from result file
        Bridge-->>ITranscription: TranscribeFileResult
    end

    ITranscription-->>VM: Result
    alt Result.Success = true
        VM-->>Result: CurrentState = Complete
        Result->>User: Show transcript preview, open-folder, copy actions
    else Result.Success = false
        VM-->>Result: CurrentState = Failed
        Result->>User: Show error, Retry, Choose Different File
    end
```

## Key Observations

**Model reuse in batch mode.** The Whisper model is loaded once before the batch loop begins. This reduces reload cost and avoids unnecessary native-runtime churn.

**Sequential file processing.** Batch mode stays single-threaded. This keeps memory usage predictable and avoids uncertain native-runtime concurrency behavior.

**Desktop state flow is explicit.** The Desktop UI is driven by `AppState` (`Ready`, `Running`, `Failed`, `Complete`) rather than router-style page navigation. `Routes.razor` exists only for startup initialization and retry.

**Desktop config merge is host-specific.** Desktop does not rely on `TRANSCRIPTION_SETTINGS_PATH` by default. It builds a merged runtime config from bundled defaults plus `~/Library/Application Support/VoxFlow/appsettings.json`.

**Intel Mac Catalyst uses the CLI bridge.** Desktop replaces the default `ITranscriptionService` with `DesktopCliTranscriptionService` on Intel Mac Catalyst. The workaround stays local and reuses the current CLI pipeline rather than forking Core logic.

**Desktop startup validation is non-blocking at the route level.** Validation failures do not crash the shell. Instead, the app stays on `ReadyView`, surfaces the failed checks, and disables file selection until the configuration is fixed.

**Desktop integrated browse flow is green.** The real UI automation suite now covers app launch, `Browse Files`, the running state, and completion against the actual `.app`.

**MCP stdout protection remains critical.** The MCP host keeps stdout reserved for JSON-RPC traffic and sends diagnostics to stderr.
