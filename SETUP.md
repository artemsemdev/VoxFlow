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
- The Desktop project now supports both `maccatalyst-x64` and `maccatalyst-arm64`, and defaults to the current `dotnet` process architecture.

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

Current limitation:

- The Settings panel UI can load values, but `Save` is not wired to persist overrides yet.
- For now, persistent Desktop overrides should be edited manually in `~/Library/Application Support/VoxFlow/appsettings.json`.

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

- First-run validation checks `ffmpeg`, model state, and writable paths
- Missing model can be downloaded from the UI
- The intended file-entry paths are drag-and-drop and `Browse Files`
- Current UI scope is single-file transcription
- Result view supports opening the output folder and copying the transcript preview
- Settings are exposed through the Desktop settings panel

Current Desktop limitations:

- Batch processing is implemented in `VoxFlow.Core`, but not exposed as a Desktop UI workflow yet
- Settings persistence from the UI is not implemented yet
- The direct `ReadyView` browse flow is covered by headless tests, but the full `Routes`-based Desktop shell still has open integration failures around `Browse Files`
- Native drag-and-drop and the system file picker are still best treated as active stabilization areas until the integrated Desktop shell is green end-to-end
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

Current verified result as of March 24, 2026:

- `VoxFlow.Core.Tests`: 50 passed
- `VoxFlow.Cli.Tests`: 6 passed
- `VoxFlow.McpServer.Tests`: 31 passed
- `VoxFlow.Desktop.Tests`: 28 passed, 2 failed, 2 skipped

Current Desktop UI interpretation:

- The direct `ReadyView` browse path passes with real audio and completes transcription
- CLI and Core processing both succeed on `Test 1.m4a` and `Test 2.m4a`
- The remaining two failures are both `Routes_BrowseFile_WithRealAudio_CompletesTranscription(...)`, which localizes the open issue to the integrated Desktop root shell rather than the transcription pipeline itself

## Troubleshooting

### The app starts in batch mode when I expected single-file mode

The checked-in root config and host configs currently default to `processingMode: "batch"`. Use `appsettings.example.json` as your single-file starting point or set `transcription.processingMode` to `"single"` in your local config.

### Desktop validation fails on batch input paths

This usually means a user override file switched Desktop back to `processingMode: "batch"` or provided batch-only relative paths. Review `~/Library/Application Support/VoxFlow/appsettings.json` and prefer single-file settings unless you are explicitly testing batch behavior outside the Desktop UI.

### Desktop shows `Ready to Transcribe`, but `Browse Files` or drag-and-drop does not start transcription

This is a known integration issue in the current Desktop shell. The repo's headless UI tests show that the direct `ReadyView -> DropZone -> AppViewModel -> VoxFlow.Core` path works with real audio, but the fully integrated `Routes`-based shell still has open `Browse Files` failures. Reproduce the current state with:

```bash
dotnet test tests/VoxFlow.Desktop.Tests/VoxFlow.Desktop.Tests.csproj \
  --filter FullyQualifiedName~DesktopUiComponentTests \
  --no-restore
```

If you need a stable transcription baseline while debugging the UI shell, use `VoxFlow.Cli` against the same input files and config.

### Local packaged app triggers macOS trust warnings

The current repo includes local packaging and checksum generation, but not a full notarized release flow. For local development, prefer `dotnet run` or `dotnet build`. Treat signed distribution, Gatekeeper compatibility, and release install instructions as separate release work.

### MCP tools fail with a missing `transcription` section

This happens when the MCP server is launched with only `src/VoxFlow.McpServer/appsettings.json` available. Set `TRANSCRIPTION_SETTINGS_PATH` to a config that contains the `transcription` section, or pass `configurationPath` on each tool call.

### `ffmpeg` is not found

Install `ffmpeg` and make sure it is on `PATH`, or set `transcription.ffmpegExecutablePath` to an absolute path such as `/opt/homebrew/bin/ffmpeg`.

### Model download is slow or blocked

Place the model file manually at the configured `modelFilePath`. The runtime will reuse an existing valid model and only download when the file is missing, empty, or unloadable.

### Desktop Settings save does not persist changes

This is a current implementation gap, not user error. Edit `~/Library/Application Support/VoxFlow/appsettings.json` manually for persistent Desktop overrides.

### `*.SdkResolver.*.proj.Backup.tmp` files appear next to `VoxFlow.Desktop.csproj`

These are temporary MSBuild SDK resolver backup files. They are not source files and should not be committed.
