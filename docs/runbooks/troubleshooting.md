# Troubleshooting

Common issues and their resolutions when working with VoxFlow.

> **Looking for a specific error message?** See the [error catalog](./error-catalog.md) — every user-facing exception and structured error in `src/` is listed there with root cause, remediation, and a link to the throwing line.

## CLI Issues

### The app starts in batch mode when I expected single-file mode

The checked-in root config and host configs currently default to `processingMode: "batch"`. Use `appsettings.example.json` as your single-file starting point or set `transcription.processingMode` to `"single"` in your local config.

### `ffmpeg` is not found

Install `ffmpeg` and make sure it is on `PATH`, or set `transcription.ffmpegExecutablePath` to an absolute path such as `/opt/homebrew/bin/ffmpeg`.

### Model download is slow or blocked

Place the model file manually at the configured `modelFilePath`. The runtime will reuse an existing valid model and only download when the file is missing, empty, or unloadable.

## Desktop Issues

### Desktop validation fails on batch input paths

This usually means a user override file switched Desktop back to `processingMode: "batch"` or provided batch-only relative paths. Review `~/Library/Application Support/VoxFlow/appsettings.json` and prefer single-file settings unless you are explicitly testing batch behavior outside the Desktop UI.

### Desktop shows a startup warning banner and `Browse Files` is disabled

The Desktop app keeps you on the ready screen when startup validation returns blocking failures. Read the message shown in the banner first; it is built from the failed validation checks. Common causes are:

- `ffmpeg` is not on `PATH`
- The configured output or model directories are not writable
- A user override switched Desktop back to an invalid batch-oriented config

Review `~/Library/Application Support/VoxFlow/appsettings.json`, then rerun the Desktop app. You can inspect the same checks from CLI with:

```bash
TRANSCRIPTION_SETTINGS_PATH=$PWD/appsettings.example.json \
dotnet run --project src/VoxFlow.Cli/VoxFlow.Cli.csproj
```

### Desktop on Intel Mac says `Running CLI transcription pipeline...`

This is expected. On `maccatalyst-x64`, the Desktop host uses `DesktopCliTranscriptionService` and launches `VoxFlow.Cli` as a local helper process. If transcription then fails immediately:

- Make sure `dotnet` is available in the environment used to start the app
- Rebuild Desktop, which also rebuilds the CLI bridge target
- If needed, build CLI directly with `dotnet build src/VoxFlow.Cli/VoxFlow.Cli.csproj --no-restore`

### Local packaged app triggers macOS trust warnings

The current repo includes local packaging and checksum generation, but not a full notarized release flow. For local development, prefer `dotnet run` or `dotnet build`. Treat signed distribution, Gatekeeper compatibility, and release install instructions as separate release work.

## MCP Issues

### MCP tools fail with a missing `transcription` section

This happens when the MCP server is launched with only `src/VoxFlow.McpServer/appsettings.json` available. Set `TRANSCRIPTION_SETTINGS_PATH` to a config that contains the `transcription` section, or pass `configurationPath` on each tool call.

## Build Issues

### `*.SdkResolver.*.proj.Backup.tmp` files appear next to `VoxFlow.Desktop.csproj`

These are temporary MSBuild SDK resolver backup files. They are not source files and should not be committed.
