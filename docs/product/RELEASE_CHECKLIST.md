# VoxFlow Desktop — Demo-Ready macOS Release Checklist

This checklist covers the steps to build, smoke-test, package, and verify a Desktop release artifact on macOS. It is intended for local demo builds, not for notarized distribution.

## Prerequisites

- macOS with Xcode command-line tools
- .NET SDK 9 with `maui-maccatalyst` workload installed
- `ffmpeg` available on `PATH`
- Whisper model file at `models/ggml-base.bin` (or configured path)

## 1. Build

```bash
dotnet restore VoxFlow.sln
dotnet build src/VoxFlow.Desktop/VoxFlow.Desktop.csproj -f net9.0-maccatalyst --no-restore
```

## 2. Run Fast Tests

```bash
dotnet test tests/VoxFlow.Desktop.Tests/VoxFlow.Desktop.Tests.csproj --no-restore
```

All tests must pass. Skipped real-audio tests are acceptable if `artifacts/Input/` files are not present.

## 3. Smoke-Test the App

```bash
dotnet run --project src/VoxFlow.Desktop/VoxFlow.Desktop.csproj -f net9.0-maccatalyst
```

Manual verification:

- [ ] App launches and shows the Ready screen with "Audio Transcription"
- [ ] Ready screen lists supported formats (M4A, WAV, MP3, etc.)
- [ ] No "upload" or "multiple files" language is visible
- [ ] Browse Files button is enabled (no blocking validation errors)
- [ ] Selecting an audio file transitions to Running screen
- [ ] Running screen shows numeric percent, human-readable stage label, and "Starting transcription..." before first progress
- [ ] Complete screen shows transcript preview, detected language, and action buttons
- [ ] Copy Text copies the full transcript (not just preview)
- [ ] Open Folder opens the output directory
- [ ] Back button returns to Ready screen with clean state
- [ ] Cancel during Running returns to Ready with no stale data

## 4. Run Real UI Automation (optional but recommended)

```bash
./scripts/run-desktop-ui-tests.sh
```

Expected green scenarios:

- `AppStartsSuccessfully_AndReadyScreenIsVisible`
- `HappyPath_UserSelectsFile_SeesRunningState_AndGetsResult`

## 5. Package

```bash
./scripts/build-macos.sh
```

The script detects the host architecture, publishes a Release build, and generates a SHA-256 checksum.

## 6. Verify the Packaged App

Launch the `.app` from the publish output directory:

```bash
open src/VoxFlow.Desktop/bin/Release/net9.0-maccatalyst/*/publish/VoxFlow.Desktop.app
```

Repeat the manual smoke checks from step 3 against the packaged app.

## Known Release Gaps

- The package is **not notarized**. macOS Gatekeeper will block the app on first launch for users who did not build it locally. Right-click > Open bypasses this for local testing.
- No `.dmg` or installer is generated. The artifact is a bare `.app` bundle or `.pkg`.
- No auto-update mechanism exists.
- Signing uses an ad-hoc identity unless a valid Apple Developer certificate is configured.
