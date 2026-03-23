# Setup & Operations Guide

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| .NET SDK | 9.0+ | [Download](https://dotnet.microsoft.com/download/dotnet/9.0) |
| ffmpeg | Any recent release | Must be on `PATH` or configured via `ffmpegExecutablePath` |
| Whisper model | ggml-format `.bin` | Auto-downloaded on first run, or place manually in `models/` |

Verify prerequisites:

```bash
dotnet --version
ffmpeg -version
```

## Project Structure

```
VoxFlow/
  Program.cs                    # Application entry point (CLI)
  Configuration/                # Settings loading and validation
  Audio/                        # ffmpeg conversion and WAV loading
  Processing/                   # Transcript filtering
  Services/                     # Model loading, language selection, progress UI,
                                # output writing, startup validation,
                                # file discovery, batch summary
  Contracts/                    # Host-agnostic DTOs (shared with MCP server)
  Facades/                      # Application facades (bridging static services to DI)
  Security/                     # Path policy for MCP tool argument validation
  appsettings.json              # Active configuration
  appsettings.example.json      # Reference template
  models/                       # Local Whisper model files
  artifacts/                    # Default input/output directory
  src/
    WhisperNET.McpServer/       # MCP server project
      Configuration/            # MCP-specific options (McpOptions)
      Tools/                    # MCP tools (6 tools)
      Prompts/                  # MCP prompts (4 guided workflows)
      Resources/                # MCP resource tools (config inspector)
      Program.cs                # MCP server entry point (DI + stdio)
      appsettings.json          # MCP server configuration
  tests/
    VoxFlow.UnitTests/
    VoxFlow.EndToEndTests/
    WhisperNET.McpServer.Tests/ # MCP server unit tests
    TestSupport/                # Shared test utilities
```

## Environment Configuration

All configuration is in `appsettings.json` under the `transcription` key. Copy the example file as a starting point:

```bash
cp appsettings.example.json appsettings.json
```

Alternatively, point the application at a different settings file:

```bash
TRANSCRIPTION_SETTINGS_PATH=/absolute/path/to/appsettings.json dotnet run
```

### Processing Mode

The `processingMode` field controls which mode the application runs in:

| Value | Behavior |
|---|---|
| `"single"` | Transcribe a single audio file (default) |
| `"batch"` | Transcribe all matching files in a directory |

### Single-File Mode Settings

```json
{
  "transcription": {
    "processingMode": "single",
    "inputFilePath": "artifacts/input.m4a",
    "wavFilePath": "artifacts/output.wav",
    "resultFilePath": "artifacts/result.txt",
    "modelFilePath": "models/ggml-base.bin",
    "ffmpegExecutablePath": "ffmpeg"
  }
}
```

| Setting | Description |
|---|---|
| `inputFilePath` | Source `.m4a` audio file |
| `wavFilePath` | Intermediate WAV file path |
| `resultFilePath` | Output transcript file path |
| `modelFilePath` | Path to the Whisper model `.bin` file |
| `ffmpegExecutablePath` | `ffmpeg` binary name or absolute path |

### Batch Mode Settings

In batch mode, `inputFilePath`, `wavFilePath`, and `resultFilePath` are optional and ignored.

```json
{
  "transcription": {
    "processingMode": "batch",
    "batch": {
      "inputDirectory": "artifacts/input",
      "outputDirectory": "artifacts/output",
      "tempDirectory": "",
      "filePattern": "*.m4a",
      "stopOnFirstError": false,
      "keepIntermediateFiles": false,
      "summaryFilePath": "artifacts/batch-summary.txt"
    },
    "modelFilePath": "models/ggml-base.bin",
    "ffmpegExecutablePath": "ffmpeg"
  }
}
```

| Setting | Default | Description |
|---|---|---|
| `batch.inputDirectory` | *(required)* | Directory to scan for input audio files |
| `batch.outputDirectory` | *(required)* | Directory for per-file `.txt` transcripts |
| `batch.tempDirectory` | System temp | Directory for intermediate `.wav` files |
| `batch.filePattern` | `*.m4a` | Glob pattern for file discovery |
| `batch.stopOnFirstError` | `false` | Halt entire batch on first failure |
| `batch.keepIntermediateFiles` | `false` | Retain intermediate `.wav` files |
| `batch.summaryFilePath` | `batch-summary.txt` | Path for the batch completion summary |

### Model Settings

| Setting | Default | Description |
|---|---|---|
| `modelType` | `Base` | Model type for `WhisperGgmlDownloader`. Options: `Base`, `LargeV3`, `LargeV3Turbo` |

### WAV Conversion Settings

| Setting | Default | Description |
|---|---|---|
| `outputSampleRate` | `16000` | Sample rate for WAV output |
| `outputChannelCount` | `1` | Channel count (mono) |
| `outputContainerFormat` | `wav` | Output container format |
| `overwriteWavOutput` | `true` | Overwrite existing WAV file |
| `audioFilterChain` | See below | Ordered ffmpeg audio filters |

Default audio filter chain:

```json
"audioFilterChain": [
  "afftdn=nf=-25",
  "silenceremove=stop_periods=-1:stop_threshold=-50dB:stop_duration=1"
]
```

This reduces background noise and removes long silent stretches before transcription.

### Language Settings

```json
"supportedLanguages": [
  { "code": "en", "displayName": "English" }
]
```

- **One language configured:** direct forced transcription in that language
- **Multiple languages configured:** per-language candidate scoring and automatic best-candidate selection

### Filtering and Scoring Settings

| Setting | Default | Description |
|---|---|---|
| `nonSpeechMarkers` | `["music", "noise", "silence", ...]` | Tokens treated as non-speech |
| `longLowInformationSegmentThresholdSeconds` | `30` | Max segment duration before flagging |
| `minTextLengthForLongSegment` | `10` | Min text length for long segments |
| `minSegmentProbability` | `0.35` | Min probability to keep a segment |
| `minWinningCandidateProbability` | `0.45` | Min probability for winning language |
| `minWinningMargin` | `0.02` | Min margin between top two candidates |
| `tieBreakerEpsilon` | `0.0001` | Epsilon for tie-breaking |
| `rejectAmbiguousLanguageCandidates` | `false` | Reject ambiguous language results |
| `minAcceptedSpeechDurationSeconds` | `2` | Min speech duration to accept |

### Anti-Hallucination Settings

| Setting | Default | Description |
|---|---|---|
| `useNoContext` | `true` | Disable cross-segment context |
| `noSpeechThreshold` | `0.75` | Threshold for no-speech detection |
| `logProbThreshold` | `-0.8` | Min log probability for segments |
| `entropyThreshold` | `2.4` | Max entropy for segments |
| `suppressBracketedNonSpeechSegments` | `true` | Filter `[music]`, `[noise]`, etc. |
| `maxConsecutiveDuplicateSegments` | `2` | Max repeated identical segments |
| `maxDuplicateSegmentTextLength` | `32` | Max text length for duplicate check |

### Startup Validation Settings

| Setting | Default | Description |
|---|---|---|
| `startupValidation.enabled` | `true` | Run preflight checks |
| `startupValidation.printDetailedReport` | `true` | Print detailed validation report |
| `startupValidation.checkInputFile` | `true` | Verify input file exists |
| `startupValidation.checkOutputDirectories` | `true` | Verify output directories exist |
| `startupValidation.checkOutputWriteAccess` | `true` | Verify write permissions |
| `startupValidation.checkFfmpegAvailability` | `true` | Verify ffmpeg is available |
| `startupValidation.checkModelType` | `true` | Validate model type |
| `startupValidation.checkModelDirectory` | `true` | Verify model directory exists |
| `startupValidation.checkModelLoadability` | `true` | Attempt to load the model |
| `startupValidation.checkLanguageSupport` | `true` | Validate language configuration |
| `startupValidation.checkWhisperRuntime` | `true` | Verify Whisper runtime loads |

### Console Progress Settings

| Setting | Default | Description |
|---|---|---|
| `consoleProgress.enabled` | `true` | Show progress bar during transcription |
| `consoleProgress.useColors` | `true` | Use ANSI colors in output |
| `consoleProgress.progressBarWidth` | `32` | Width of the progress bar |
| `consoleProgress.refreshIntervalMilliseconds` | `120` | Progress bar refresh interval |

## MCP Server Configuration

The MCP server (`WhisperNET.McpServer`) exposes VoxFlow's transcription capabilities to AI clients via the Model Context Protocol.

### MCP Server Settings

The MCP server loads configuration from `src/WhisperNET.McpServer/appsettings.json` under the `mcp` key:

```json
{
  "mcp": {
    "enabled": true,
    "transport": "stdio",
    "serverName": "whispernet",
    "serverVersion": "1.0.0",
    "allowBatch": true,
    "allowedInputRoots": [],
    "allowedOutputRoots": [],
    "maxBatchFiles": 100,
    "requireAbsolutePaths": true
  }
}
```

| Setting | Default | Description |
|---|---|---|
| `serverName` | `whispernet` | MCP server identity name |
| `serverVersion` | `1.0.0` | MCP server version |
| `allowBatch` | `true` | Enable/disable batch transcription tool |
| `allowedInputRoots` | `[]` | Allowed input root directories (empty = any absolute path) |
| `allowedOutputRoots` | `[]` | Allowed output root directories (empty = any absolute path) |
| `maxBatchFiles` | `100` | Maximum files per batch invocation |
| `requireAbsolutePaths` | `true` | Require absolute paths in MCP tool arguments |

### Path Safety

When `allowedInputRoots` and `allowedOutputRoots` are empty, any absolute path is accepted. To restrict file access:

```json
{
  "mcp": {
    "allowedInputRoots": ["/Users/me/audio"],
    "allowedOutputRoots": ["/Users/me/transcripts"]
  }
}
```

### VS Code MCP Client Configuration

To use the MCP server from VS Code, add to `.vscode/mcp.json`:

```json
{
  "servers": {
    "whispernet": {
      "type": "stdio",
      "command": "dotnet",
      "args": ["run", "--project", "src/WhisperNET.McpServer"]
    }
  }
}
```

### Available MCP Tools

| Tool | Description |
|------|-------------|
| `validate_environment` | Run startup validation and return diagnostics |
| `transcribe_file` | Transcribe a single audio file |
| `transcribe_batch` | Batch transcribe a directory of files |
| `get_supported_languages` | Return configured supported languages |
| `inspect_model` | Inspect Whisper model status |
| `read_transcript` | Read a previously produced transcript |
| `get_effective_config` | Return resolved configuration snapshot |

### Available MCP Prompts

| Prompt | Description |
|--------|-------------|
| `transcribe-local-audio` | Guide through single-file transcription |
| `batch-transcribe-folder` | Guide through batch transcription |
| `diagnose-transcription-setup` | Diagnose environment issues |
| `inspect-last-transcript` | Review a transcript file |

## Local Installation

```bash
git clone <repository-url>
cd VoxFlow
dotnet restore
dotnet build
```

## Running the Application

### Single-file mode

1. Place your audio file at the configured `inputFilePath` (default: `artifacts/input.m4a`)
2. Run:

```bash
dotnet run
```

### Batch mode

1. Set `processingMode` to `"batch"` in `appsettings.json`
2. Place audio files in the configured `batch.inputDirectory`
3. Run:

```bash
dotnet run
```

### MCP Server mode

Run the MCP server directly (typically launched by an AI client):

```bash
dotnet run --project src/WhisperNET.McpServer
```

### Output

The application prints a startup-validation report before processing:

- `PASSED` -- all checks pass, processing begins
- `PASSED WITH WARNINGS` -- non-critical issues detected, processing begins
- `FAILED` -- critical issues found, processing does not start

In batch mode, the progress bar shows a `[File X/Y]` prefix. After completion, a summary report is written to `batch.summaryFilePath`.

Transcript output format:

```text
00:00:01.2000000->00:00:03.8000000: Hello, this is a test.
```

## Testing

Run unit tests:

```bash
dotnet test tests/VoxFlow.UnitTests/VoxFlow.UnitTests.csproj
```

Run end-to-end tests:

```bash
dotnet test tests/VoxFlow.EndToEndTests/VoxFlow.EndToEndTests.csproj
```

Run MCP server tests:

```bash
dotnet test tests/WhisperNET.McpServer.Tests/WhisperNET.McpServer.Tests.csproj
```

Run all tests:

```bash
dotnet test
```

Tests do not require real audio files or a checked-in Whisper model. They generate temporary settings, create a fake `ffmpeg` executable, and use generated WAV fixtures. MCP server tests cover path policy, configuration, contracts, and facade behavior.

## Common Troubleshooting

### Startup validation fails on input file in batch mode

Make sure `processingMode` is set to `"batch"` in `appsettings.json`. In batch mode, the single-file `inputFilePath` is ignored and the `batch.inputDirectory` is used instead.

### ffmpeg not found

Ensure `ffmpeg` is installed and either on your system `PATH` or set `ffmpegExecutablePath` to the absolute path of the `ffmpeg` binary.

### Model download fails or is slow

Place the model file manually in the `models/` directory. The expected filename matches `modelType` (e.g., `ggml-base.bin` for `Base`).

### Low transcription quality

- Try a larger model (`LargeV3` or `LargeV3Turbo` instead of `Base`)
- Adjust `audioFilterChain` for your audio characteristics
- Tune `noSpeechThreshold`, `logProbThreshold`, and `entropyThreshold`
