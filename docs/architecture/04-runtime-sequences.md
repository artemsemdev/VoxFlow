# Runtime Sequences

> How the application behaves at runtime — sequence diagrams for both processing modes.

## Single-File Mode

```mermaid
sequenceDiagram
    participant User
    participant Program
    participant Config as TranscriptionOptions
    participant Validation as StartupValidationService
    participant FFmpeg as AudioConversionService
    participant Model as ModelService
    participant Loader as WavAudioLoader
    participant Lang as LanguageSelectionService
    participant Filter as TranscriptionFilter
    participant Writer as OutputWriter

    User->>Program: dotnet run
    Program->>Config: Load()
    Config-->>Program: Immutable options

    Program->>Validation: ValidateAsync(options)
    alt Validation failed
        Validation-->>Program: Report with failures
        Program-->>User: Exit 1 with diagnostics
    end
    Validation-->>Program: Report (passed/warnings)

    Program->>FFmpeg: ConvertToWavAsync(input, output)
    FFmpeg->>FFmpeg: Spawn ffmpeg process
    FFmpeg-->>Program: WAV file written

    Program->>Model: CreateFactoryAsync(options)
    Model-->>Program: WhisperFactory

    Program->>Loader: LoadSamplesAsync(wavPath)
    Loader-->>Program: float[] samples

    Program->>Lang: SelectBestCandidateAsync(factory, samples, options)

    alt Single language configured
        Lang->>Lang: CreateProcessor(language)
        Lang->>Lang: TranscribeCandidateAsync()
        Lang->>Filter: FilterSegments(rawSegments)
        Filter-->>Lang: CandidateFilteringResult
    else Multiple languages configured
        loop For each configured language
            Lang->>Lang: CreateProcessor(language)
            Lang->>Lang: TranscribeCandidateAsync()
            Lang->>Filter: FilterSegments(rawSegments)
            Filter-->>Lang: CandidateFilteringResult
            Lang->>Lang: CalculateWeightedScore()
        end
        Lang->>Lang: DecideWinningCandidate()
    end

    Lang-->>Program: LanguageSelectionDecision

    alt No winning candidate
        Program-->>User: Exit 1
    end

    Program->>Writer: WriteAsync(segments, outputPath)
    Writer-->>Program: File written

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
    participant Facade as Application Facade
    participant Pipeline as VoxFlow Pipeline

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

    McpServer->>Facade: TranscribeFileAsync(request)
    Facade->>Pipeline: Convert → Model → Load → Infer → Filter → Write
    Pipeline-->>Facade: Pipeline result
    Facade-->>McpServer: TranscribeFileResultDto

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

## Key Observations

**Model reuse in batch mode.** The Whisper model is loaded once before the file loop begins. This is a deliberate choice (ADR-010, ADR-011) — loading a GGML model is expensive, and native runtime teardown on macOS has shown instability. Sharing the factory across files trades theoretical resource isolation for practical stability.

**Sequential file processing.** Files are processed one at a time within the loop. There is no parallelism. This keeps memory usage predictable, avoids native runtime contention, and simplifies error isolation (see ADR-011).

**Error isolation.** Each file in the batch loop has its own try/catch. A failure in one file records the error and continues to the next (unless `stopOnFirstError` is configured). The summary report at the end provides a clear picture of what succeeded and what failed.

**Temp WAV cleanup.** Intermediate WAV files are deleted after each file completes processing. This bounds disk usage during long batch runs. The `keepIntermediateFiles` option exists for debugging.

**MCP stdout protection.** The MCP server redirects `Console.SetOut(Console.Error)` at startup. This ensures that any diagnostic writes from VoxFlow services go to stderr, keeping the stdout channel clean for MCP JSON-RPC protocol frames.

**MCP path validation.** Every file path from an MCP tool argument passes through `PathPolicy` before reaching the application facades. This is a hard security boundary — paths outside configured allowed roots are rejected with an error response, never reaching the file system.
