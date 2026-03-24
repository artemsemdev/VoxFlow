# Setup Guide

This guide is aligned with the current repository layout, solution structure, and product docs in `README.md`, `ARCHITECTURE.md`, `docs/architecture/`, and `docs/product/`.

All commands below assume your shell is running from the repository root.

## Current Solution

VoxFlow is no longer a single console app. The active solution contains four projects:

| Project | Role | Target |
|---|---|---|
| `src/VoxFlow.Core` | Shared transcription pipeline, configuration, validation, model handling, output writing | `net9.0` |
| `src/VoxFlow.Cli` | Thin CLI host over `VoxFlow.Core` | `net9.0` |
| `src/VoxFlow.McpServer` | Stdio MCP host over `VoxFlow.Core` | `net9.0` |
| `src/VoxFlow.Desktop` | MAUI Blazor Hybrid macOS desktop app | `net9.0-maccatalyst` |

Active test projects:

| Project | Purpose |
|---|---|
| `tests/VoxFlow.Core.Tests` | Core unit tests |
| `tests/VoxFlow.Cli.Tests` | CLI end-to-end and regression tests |
| `tests/VoxFlow.McpServer.Tests` | MCP configuration and path-policy tests |
| `tests/VoxFlow.Desktop.Tests` | Desktop view-model, configuration, headless Razor UI/component, and UI integration tests |
| `tests/VoxFlow.Desktop.UiTests` | Real macOS desktop UI automation against the built `.app` bundle |

## Scope

This file documents source-based setup, local builds, and local runtime behavior.

The latest docs in `docs/product/` and `docs/architecture/` define some broader Phase 1 release goals. Current repo status is:

- Desktop scope is single-file transcription UI; batch UI is explicitly out of current Desktop scope
- MCP remains a separate stdio host and is not part of the Desktop UI
- Local macOS packaging exists via `scripts/build-macos.sh`
- Full signed/notarized release-install workflow, Gatekeeper guidance, and uninstall notes are Phase goals, but are not fully automated in the current repo scripts

## Prerequisites

| Dependency | Required For | Notes |
|---|---|---|
| .NET SDK 9 | All hosts | `dotnet restore`, `build`, `run`, and `test` |
| `ffmpeg` | CLI, Desktop, MCP transcription | Must be on `PATH` or configured via `ffmpegExecutablePath` |
| Writable `models/` directory | CLI, Desktop, MCP transcription | Model is reused if present; downloaded if missing |
| macOS + Xcode command-line tools | Desktop | Required for Mac Catalyst builds |
| `maui-maccatalyst` workload | Desktop | Install with `dotnet workload install maui-maccatalyst` |

Notes:

- Runtime transcription is local, but the first model download requires network access unless you place the GGML model file manually.
- The Desktop project targets both `maccatalyst-x64` and `maccatalyst-arm64`, and defaults to the current `dotnet` process architecture.
- Apple Silicon Desktop runs the shared Core transcription pipeline in-process.
- Intel Mac Catalyst Desktop uses a local CLI bridge for transcription so the UI follows the same working path as `VoxFlow.Cli`.

Environment checks:

```bash
dotnet --version
dotnet workload list
ffmpeg -version
```

Verified development environment for this guide:

- `.NET SDK`: `9.0.312`
- `dotnet workload list`: `maui-maccatalyst`
- `ffmpeg`: `7.1.1`

## Repository Bootstrap

Restore dependencies:

```bash
dotnet restore VoxFlow.sln
```

Recommended working directories:

```bash
mkdir -p artifacts/input artifacts/output models
```

If you want a fresh local config without editing tracked files, create one from the example:

```bash
cp appsettings.example.json appsettings.local.json
```

## Configuration Model

### Shared Transcription Settings

`VoxFlow.Core` resolves transcription settings in this order:

1. Explicit `configurationPath` passed by the caller
2. `TRANSCRIPTION_SETTINGS_PATH`
3. `appsettings.json` next to the running host

Relevant files in this repo:

| File | Purpose |
|---|---|
| `appsettings.example.json` | Combined example file with `transcription` and `mcp` sections; starts in single-file mode |
| `appsettings.json` | Shared root development config; currently batch-oriented |
| `src/VoxFlow.Cli/appsettings.json` | CLI runtime config copied to CLI output |
| `src/VoxFlow.Desktop/appsettings.json` | Bundled Desktop defaults |
| `src/VoxFlow.McpServer/appsettings.json` | MCP host settings; contains only the `mcp` section |

Important:

- The checked-in root config and host configs currently default to `processingMode: "batch"`.
- `src/VoxFlow.Desktop/appsettings.json` now defaults to Desktop-oriented single-file behavior.
- `appsettings.example.json` is the easiest starting point for single-file CLI runs.
- Relative paths such as `artifacts/output` and `models/ggml-base.bin` are easiest to reason about when you run commands from the repo root.

### Desktop Configuration Resolution

`VoxFlow.Desktop` does not use `TRANSCRIPTION_SETTINGS_PATH` by default. Instead it merges:

1. Bundled `appsettings.json` inside the app
2. User overrides at `~/Library/Application Support/VoxFlow/appsettings.json`
3. An explicit override path only when a caller passes one programmatically

Desktop-specific notes:

- Persistent Desktop overrides are file-based. Edit `~/Library/Application Support/VoxFlow/appsettings.json` directly.
- `DesktopConfigurationService` writes a temporary merged snapshot before startup and before any CLI-bridge invocation.
- When the Intel CLI bridge is active, the startup snapshot disables in-process Whisper-specific validation checks (`checkModelLoadability`, `checkWhisperRuntime`, `checkLanguageSupport`) so the app can start and delegate transcription to CLI. The actual CLI transcription run still uses the full merged config.

Example Desktop override file:

```json
{
  "transcription": {
    "processingMode": "single",
    "ffmpegExecutablePath": "/opt/homebrew/bin/ffmpeg",
    "modelType": "Base"
  }
}
```

For Desktop development, prefer absolute paths in user overrides for `modelFilePath`, `wavFilePath`, and `resultFilePath`.
Bundled Desktop defaults already resolve into `~/Library/Application Support/VoxFlow/` and `~/Documents/VoxFlow/`.

### MCP Configuration

`src/VoxFlow.McpServer/appsettings.json` currently contains only MCP host settings:

```json
{
  "mcp": {
    "enabled": true,
    "transport": "stdio",
    "serverName": "voxflow",
    "serverVersion": "1.0.0",
    "allowBatch": true,
    "allowedInputRoots": [],
    "allowedOutputRoots": [],
    "maxBatchFiles": 100,
    "requireAbsolutePaths": true
  }
}
```

Important:

- MCP tools that need transcription settings must get them from `configurationPath` or `TRANSCRIPTION_SETTINGS_PATH`.
- If you launch the MCP server without either of those, the host starts, but transcription-related tool calls will not have a default `transcription` section to load.
- With empty `allowedInputRoots` and `allowedOutputRoots`, any absolute path is accepted.
- `requireAbsolutePaths` defaults to `true`.

## Build

Build the CLI:

```bash
dotnet build src/VoxFlow.Cli/VoxFlow.Cli.csproj --no-restore
```

Build the MCP server:

```bash
dotnet build src/VoxFlow.McpServer/VoxFlow.McpServer.csproj --no-restore
```

Build the Desktop app:

```bash
dotnet build src/VoxFlow.Desktop/VoxFlow.Desktop.csproj -f net9.0-maccatalyst --no-restore
```

Desktop builds automatically invoke the `BuildDesktopCliBridge` target first, which builds `src/VoxFlow.Cli` for `net9.0`. This keeps the Intel Mac Desktop bridge aligned with the current CLI code without adding an executable project reference.

Package the Desktop app:

```bash
./scripts/build-macos.sh
```

The packaging script detects the host architecture, publishes `src/VoxFlow.Desktop` for the matching Mac Catalyst runtime identifier, and writes a SHA-256 checksum for the generated `.pkg` or `.app` artifact when found.

Important:

- This is a local packaging helper, not a complete release pipeline
- The current script does not perform notarization or Gatekeeper-specific release handling
- If you need release-grade macOS distribution, treat signing, notarization, and install docs as separate work

## Running VoxFlow

### CLI: Single File

Use a dedicated config file based on the example:

```bash
cp appsettings.example.json appsettings.local.json
```

Edit at least these fields in `appsettings.local.json`:

- `transcription.processingMode`
- `transcription.inputFilePath`
- `transcription.wavFilePath`
- `transcription.resultFilePath`
- `transcription.modelFilePath`
- `transcription.ffmpegExecutablePath` if `ffmpeg` is not on `PATH`

Run:

```bash
TRANSCRIPTION_SETTINGS_PATH=$PWD/appsettings.local.json \
dotnet run --project src/VoxFlow.Cli/VoxFlow.Cli.csproj
```

### CLI: Batch

The checked-in root `appsettings.json` already uses batch mode. Adjust it or point the CLI to a custom batch config.

Run with the root config:

```bash
TRANSCRIPTION_SETTINGS_PATH=$PWD/appsettings.json \
dotnet run --project src/VoxFlow.Cli/VoxFlow.Cli.csproj
```

Relevant batch settings:

- `transcription.batch.inputDirectory`
- `transcription.batch.outputDirectory`
- `transcription.batch.tempDirectory`
- `transcription.batch.filePattern`
- `transcription.batch.summaryFilePath`

### Desktop

Run the macOS desktop app:

```bash
dotnet run --project src/VoxFlow.Desktop/VoxFlow.Desktop.csproj -f net9.0-maccatalyst
```

Recommended before first launch:

- Create `~/Library/Application Support/VoxFlow/appsettings.json`
- Override bundled defaults only if you want different output/model locations
- Use absolute paths in overrides when you want fully explicit locations
- On Intel Mac, expect Desktop transcription to launch `VoxFlow.Cli` under the hood after file selection. On Apple Silicon, the Desktop app transcribes in-process.

## Real Desktop UI Automation

`tests/VoxFlow.Desktop.UiTests` launches the real Mac Catalyst app bundle and drives the actual desktop window through macOS Accessibility plus the native Open dialog. This is separate from the headless Razor/component tests in `tests/VoxFlow.Desktop.Tests`.

Prerequisites:

- macOS
- Built Desktop app bundle
- `ffmpeg` available on `PATH`
- `models/ggml-base.bin` present locally
- Accessibility permission granted in `System Settings > Privacy & Security > Accessibility`
  - Allow your terminal app, IDE, and the `dotnet`/`osascript` host that runs the tests
- `VoxFlow.Desktop` should not already be running before the suite starts

Build the Desktop app for the current Mac architecture:

```bash
dotnet build src/VoxFlow.Desktop/VoxFlow.Desktop.csproj -f net9.0-maccatalyst
```

Run the real UI automation suite:

```bash
VOXFLOW_RUN_DESKTOP_UI_TESTS=1 \
dotnet test tests/VoxFlow.Desktop.UiTests/VoxFlow.Desktop.UiTests.csproj
```

Or use the helper script:

```bash
./scripts/run-desktop-ui-tests.sh
```

The helper script now prints timing for both the Desktop build step and the UI test step, and writes a timestamped `trx` report plus timing logs under:

```bash
artifacts/test-results/desktop-ui/<utc-timestamp>/
```

Typical files in that directory:

- `desktop-ui-<utc-timestamp>.trx`
- `build.time.txt`
- `test.time.txt`
- `progress.log`

During execution, the helper script also prints live progress lines to the console with prefixes such as:

- `[ui-progress]`
- `[heartbeat]`

This makes it easier to distinguish between:

- active scenario steps, such as app launch, waiting for a window, opening the file dialog, waiting for the result screen
- long-running but healthy waits
- likely hangs, where only the heartbeat continues and no new UI progress appears

Optional environment variable:

- `VOXFLOW_DESKTOP_UI_APP_PATH`
  - Set this when you want the suite to target a specific built `.app` bundle instead of the default `Debug/net9.0-maccatalyst/<rid>/VoxFlow.Desktop.app`

Current coverage in the real UI suite:

- app starts and renders the main ready screen
- primary `Browse Files` action works against the native file picker
- single-file happy path reaches the final result screen
- transcript copy action updates the system clipboard
- corrupt/invalid audio drives the real failure screen and recovery flow
- repeated sequential processing works without restarting the app

Diagnostics on failure:

- full-screen screenshot under `artifacts/ui-tests/<timestamp>-<scenario>/diagnostics/`
- accessibility snapshot of the active app window
- captured Desktop process log

Current Desktop flow:

- App startup runs through `Routes.razor`, loads a merged Desktop config, and validates the resolved options before the main shell renders
- The main UI flow is driven by `AppViewModel` state: `Ready`, `Running`, `Failed`, `Complete`
- `ReadyView` shows a blocking validation banner only when startup validation contains failures; `Browse Files` and the `DropZone` surface are disabled in that state
- The intended file-entry paths are native drag-and-drop and `Browse Files`; current end-to-end automation covers the `Browse Files` path against the real macOS Open dialog
- Current UI scope is single-file transcription
- `RunningView` shows progress stage, message, percentage, elapsed time, and current language when available
- `CompleteView` supports opening the output folder and copying the transcript preview
- `FailedView` supports retrying the same file or returning to the ready screen
- Intel Mac Catalyst uses `DesktopCliTranscriptionService` to spawn the local CLI host with a merged temp config; Apple Silicon keeps transcription in-process

Current Desktop limitations:

- Batch processing is implemented in `VoxFlow.Core`, but not exposed as a Desktop UI workflow yet
- The current Desktop UI does not expose a settings editor; persistent overrides remain file-based in `~/Library/Application Support/VoxFlow/appsettings.json`
- Intel bridge execution depends on a usable local `dotnet` host and a buildable or already-built `VoxFlow.Cli`
- MCP setup, MCP diagnostics, and MCP controls are intentionally outside the current Desktop UI scope

### MCP Server

Recommended launch command:

```bash
TRANSCRIPTION_SETTINGS_PATH=$PWD/appsettings.json \
dotnet run --project src/VoxFlow.McpServer/VoxFlow.McpServer.csproj
```

This uses the root `appsettings.json` for `transcription` settings and the MCP host project config for the `mcp` section.

Behavior notes:

- Transport is stdio-only
- MCP diagnostics are redirected to stderr; stdout is reserved for protocol frames
- PathPolicy validates tool-provided paths against `allowedInputRoots`, `allowedOutputRoots`, and `requireAbsolutePaths`

Available MCP tools:

- `validate_environment`
- `transcribe_file`
- `transcribe_batch`
- `get_supported_languages`
- `inspect_model`
- `read_transcript`
- `get_effective_config`

Available MCP prompts:

- `transcribe-local-audio`
- `batch-transcribe-folder`
- `diagnose-transcription-setup`
- `inspect-last-transcript`

## Testing

Run individual test projects:

```bash
dotnet test tests/VoxFlow.Core.Tests/VoxFlow.Core.Tests.csproj --no-restore
dotnet test tests/VoxFlow.Cli.Tests/VoxFlow.Cli.Tests.csproj --no-restore
dotnet test tests/VoxFlow.McpServer.Tests/VoxFlow.McpServer.Tests.csproj --no-restore
dotnet test tests/VoxFlow.Desktop.Tests/VoxFlow.Desktop.Tests.csproj --no-restore
```

Run the full solution:

```bash
dotnet test VoxFlow.sln --no-restore
```

Run only the Desktop UI/component suite:

```bash
dotnet test tests/VoxFlow.Desktop.Tests/VoxFlow.Desktop.Tests.csproj \
  --filter FullyQualifiedName~DesktopUiComponentTests \
  --no-restore
```

Desktop UI integration fixtures currently used in the repo:

- `artifacts/Input/Test 1.m4a`
- `artifacts/Input/Test 2.m4a`

Recommended local smoke checks:

```bash
dotnet test tests/VoxFlow.Core.Tests/VoxFlow.Core.Tests.csproj --no-restore
dotnet test tests/VoxFlow.Cli.Tests/VoxFlow.Cli.Tests.csproj --no-restore
dotnet test tests/VoxFlow.McpServer.Tests/VoxFlow.McpServer.Tests.csproj --no-restore
dotnet test tests/VoxFlow.Desktop.Tests/VoxFlow.Desktop.Tests.csproj --no-restore
./scripts/run-desktop-ui-tests.sh --filter HappyPath_UserSelectsFile_SeesRunningState_AndGetsResult
```

Most recent Desktop E2E baseline:

- the integrated Desktop shell launches successfully
- `Browse Files` reaches the native picker and starts transcription
- the UI transitions through `Ready -> Running -> Complete`
- transcript output is created and surfaced back in the Desktop result view

## Troubleshooting

### The app starts in batch mode when I expected single-file mode

The checked-in root config and host configs currently default to `processingMode: "batch"`. Use `appsettings.example.json` as your single-file starting point or set `transcription.processingMode` to `"single"` in your local config.

### Desktop validation fails on batch input paths

This usually means a user override file switched Desktop back to `processingMode: "batch"` or provided batch-only relative paths. Review `~/Library/Application Support/VoxFlow/appsettings.json` and prefer single-file settings unless you are explicitly testing batch behavior outside the Desktop UI.

### Desktop shows a startup warning banner and `Browse Files` is disabled

The Desktop app now keeps you on the ready screen when startup validation returns blocking failures. Read the message shown in the banner first; it is built from the failed validation checks. Common causes are:

- `ffmpeg` is not on `PATH`
- the configured output or model directories are not writable
- a user override switched Desktop back to an invalid batch-oriented config

Review `~/Library/Application Support/VoxFlow/appsettings.json`, then rerun the Desktop app. You can inspect the same checks from CLI with:

```bash
TRANSCRIPTION_SETTINGS_PATH=$PWD/appsettings.example.json \
dotnet run --project src/VoxFlow.Cli/VoxFlow.Cli.csproj
```

### Desktop on Intel Mac says `Running CLI transcription pipeline...`

This is expected. On `maccatalyst-x64`, the Desktop host uses `DesktopCliTranscriptionService` and launches `VoxFlow.Cli` as a local helper process. If transcription then fails immediately:

- make sure `dotnet` is available in the environment used to start the app
- rebuild Desktop, which also rebuilds the CLI bridge target
- if needed, build CLI directly with `dotnet build src/VoxFlow.Cli/VoxFlow.Cli.csproj --no-restore`

### Local packaged app triggers macOS trust warnings

The current repo includes local packaging and checksum generation, but not a full notarized release flow. For local development, prefer `dotnet run` or `dotnet build`. Treat signed distribution, Gatekeeper compatibility, and release install instructions as separate release work.

### MCP tools fail with a missing `transcription` section

This happens when the MCP server is launched with only `src/VoxFlow.McpServer/appsettings.json` available. Set `TRANSCRIPTION_SETTINGS_PATH` to a config that contains the `transcription` section, or pass `configurationPath` on each tool call.

### `ffmpeg` is not found

Install `ffmpeg` and make sure it is on `PATH`, or set `transcription.ffmpegExecutablePath` to an absolute path such as `/opt/homebrew/bin/ffmpeg`.

### Model download is slow or blocked

Place the model file manually at the configured `modelFilePath`. The runtime will reuse an existing valid model and only download when the file is missing, empty, or unloadable.

### `*.SdkResolver.*.proj.Backup.tmp` files appear next to `VoxFlow.Desktop.csproj`

These are temporary MSBuild SDK resolver backup files. They are not source files and should not be committed.
