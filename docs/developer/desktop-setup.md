# Desktop developer setup

This guide is the Desktop-specific overlay on top of the general [Developer Setup Guide](./setup.md). The general guide covers .NET SDK and dependency basics; this one focuses on the macOS / Xcode / MAUI prerequisites that `src/VoxFlow.Desktop` (Mac Catalyst MAUI Blazor Hybrid) needs to build, run, and test on a clean machine.

Use this guide when you can build `VoxFlow.Cli` / `VoxFlow.McpServer` cleanly but `VoxFlow.Desktop` does not build or launch.

## 1. Required versions

VoxFlow's CI pins what works today. Matching CI is the safest first run.

| Component | CI target | What it means locally |
|---|---|---|
| **macOS** | `macos-latest` (GitHub-hosted, currently macOS 14 / 15) — see [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) `desktop` job `runs-on:` line | Any supported macOS version is fine for development. Mac Catalyst 15.0 is the deployment floor; see `<SupportedOSPlatformVersion>` in `src/VoxFlow.Desktop/VoxFlow.Desktop.csproj`. |
| **Xcode** | Whatever ships on the runner image | Install via the Mac App Store. `xcode-select --install` (command-line tools only) is **not enough** — full Xcode is required for Mac Catalyst codesigning toolchain. After install run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` to make sure the right one is active. |
| **.NET SDK** | `9.0.x` via `actions/setup-dotnet@v4` | Install via [https://dotnet.microsoft.com/](https://dotnet.microsoft.com/) **or** rely on the repo's [`global.json`](../../global.json) which pins `9.0.100` + `rollForward: latestFeature`. Any local 9.0.x SDK works. |
| **`maui-maccatalyst` workload** | Installed by the CI step `dotnet workload install maui-maccatalyst` ([`ci.yml`](../../.github/workflows/ci.yml) `desktop` job) | Run the same command locally. The workload bundles Mac Catalyst-specific MSBuild targets, `Microsoft.Maui.Sdk`, and the metadata under `$(MauiVersion)`. |
| **Architecture** | Both `maccatalyst-x64` and `maccatalyst-arm64` build out of the box | Apple Silicon runs Whisper in-process. Intel Mac uses a local CLI bridge (`DesktopCliTranscriptionService`) because `Whisper.net.Runtime` 1.9.0 ships arm64-only Catalyst archives. |

Quick environment check:

```bash
sw_vers                            # macOS version
xcodebuild -version                # Xcode version
xcode-select -p                    # Active Xcode path
dotnet --version                   # 9.0.x
dotnet workload list               # Includes 'maui-maccatalyst'
```

## 2. Workload install

The single command that turns a fresh .NET SDK into a Mac Catalyst-capable one:

```bash
dotnet workload install maui-maccatalyst
```

This is the exact line CI runs in [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) (`desktop` job, `Install MAUI workload` step). If you ever update the workload manifest on master, the same command picks up the new version locally.

After install, `dotnet workload list` should include a row like:

```
Installed Workload Id      Manifest Version
---------------------------------------------------
maui-maccatalyst           9.0.xxxxxxxxx/9.0.100
```

## 3. Local signing

Mac Catalyst builds need code-signing metadata even for development; the question is whether the build needs a real signing identity or not. CI uses the **SDK-only-link, no signing** path; local developers usually want the same for headless work and the **personal signing identity** path for launching the app.

### Path A — headless / tests only (matches CI)

```bash
dotnet build src/VoxFlow.Desktop/VoxFlow.Desktop.csproj \
  -f net9.0-maccatalyst \
  -p:MtouchLink=SdkOnly
```

`MtouchLink=SdkOnly` is exactly the property [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) sets on its `Build desktop app` step. It bypasses the full IL-linker that requires Mac Catalyst metadata tokens (Intel Mac Catalyst builds produced an invalid token under full link, hence the project's `<MtouchLink Condition="'$(MtouchLink)' == ''">SdkOnly</MtouchLink>` default). With this property:

- No provisioning profile required.
- No personal Apple Developer team needed.
- The build emits `bin/Debug/net9.0-maccatalyst/VoxFlow.Desktop.app` you can poke at on disk.
- `VoxFlow.Desktop.Tests` runs against the produced bundle.

### Path B — launching the app (`dotnet run`)

If you want to actually click around in the app, you need a personal signing identity:

1. Open Xcode → Settings → Accounts → add your Apple ID. This creates a "Personal Team".
2. Once, in Xcode: create an empty Mac Catalyst project, pick the personal team, let Xcode generate a free provisioning profile. This trains the keychain.
3. From the repo:
   ```bash
   dotnet run --project src/VoxFlow.Desktop/VoxFlow.Desktop.csproj -f net9.0-maccatalyst
   ```

If the app refuses to launch with a Gatekeeper warning ("VoxFlow.app cannot be opened because the developer cannot be verified"), it is signed but not notarized. For local development right-click → Open the first time, or `xattr -dr com.apple.quarantine path/to/VoxFlow.Desktop.app`.

## 4. First-run troubleshooting

The seven errors a new contributor is most likely to hit and the one-line fix for each.

| Error / symptom | Root cause | Fix |
|---|---|---|
| `error MSB4236: The SDK 'Microsoft.NET.Sdk.Razor' specified could not be found.` | Razor SDK not installed; .NET SDK or workload too old. | Update to .NET SDK 9.0.x; run `dotnet workload install maui-maccatalyst`. |
| `Workload 'maui-maccatalyst' is not installed.` or `error NETSDK1147: To build this project, the following workloads must be installed: maui-maccatalyst` | MAUI workload missing. | `dotnet workload install maui-maccatalyst` |
| `error : The current .NET SDK does not support targeting .NET 9.0` | Local SDK is older than 9.0. `global.json` pins `9.0.100` minimum. | Install .NET 9 SDK (https://dotnet.microsoft.com/). |
| `xcrun: error: invalid active developer path` or `error: tool 'xcrun' requires Xcode` | Xcode command-line tools are installed but full Xcode is not active. | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` after installing full Xcode from the Mac App Store. |
| `error: No code signing identities found.` or `error: No profiles for 'com.voxflow.desktop' were found` | Trying to sign without a personal team configured. | Build with `-p:MtouchLink=SdkOnly` for headless work, OR follow Path B above to set up a personal Apple Developer team. |
| `Whisper runtime is not supported in VoxFlow Desktop on Intel Macs.` (Desktop blocking-validation banner) | Apple Silicon-only Whisper.net Catalyst archives on `maccatalyst-x64`. Expected — Desktop falls back to the CLI bridge. | Make sure `VoxFlow.Cli` builds on `net9.0` (Desktop's `BuildDesktopCliBridge` target rebuilds it automatically). On `maccatalyst-x64` the Desktop app shells out to `VoxFlow.Cli` for transcription. See [troubleshooting.md](../runbooks/troubleshooting.md) "Desktop on Intel Mac says `Running CLI transcription pipeline...`". |
| `*.SdkResolver.*.proj.Backup.tmp` files appearing next to `VoxFlow.Desktop.csproj` | MSBuild SDK resolver writes backups during workload changes. | Safe to delete; they are gitignored. See [troubleshooting.md](../runbooks/troubleshooting.md). |

If your error is not in this table, check:

- [Error catalog](../runbooks/error-catalog.md) — every user-facing runtime error has a row with root cause + remediation.
- [Troubleshooting](../runbooks/troubleshooting.md) — runtime / config problems including Desktop-specific items.

## 5. Running tests locally

CI runs the **headless Desktop suite** on macOS-latest. Locally, you have two suites with different setups.

### `VoxFlow.Desktop.Tests` — headless (CI matches this)

This is the suite the `desktop` CI job runs. Razor / view-model / configuration tests; no real `.app` bundle launch, no real audio. The Mac Catalyst build step that comes before it has skip baseline 2 — `DesktopCliBundleTests` skip on CI because `MtouchLink=SdkOnly` produces a bundle without `CopyBundledCliBridge` artifacts. Same baseline locally with the SdkOnly build.

```bash
# Build the bundle (matches CI's pre-test step)
dotnet build src/VoxFlow.Desktop/VoxFlow.Desktop.csproj \
  -f net9.0-maccatalyst -p:MtouchLink=SdkOnly

# Run the suite
dotnet test tests/VoxFlow.Desktop.Tests/VoxFlow.Desktop.Tests.csproj --no-restore
```

Expected baseline: `Passed: 145, Skipped: 2, Total: 147`. The 2 skips are the bundle-content tests (see [`phase-1-manual-verification.md`](../delivery/local-speaker-labeling/phase-1-manual-verification.md) baseline table).

Real-audio integration tests inside this suite are gated by an opt-in env var so they don't run by default:

```bash
export VOXFLOW_RUN_DESKTOP_REAL_AUDIO_TESTS=1
# Optionally point at a different fixture location:
export VOXFLOW_TEST_FIXTURES_DIR=$HOME/voxflow-fixtures
dotnet test tests/VoxFlow.Desktop.Tests/VoxFlow.Desktop.Tests.csproj --no-restore
```

Fixtures must include `Test 1.m4a` and `Test 2.m4a`. Without the env var, the `[DesktopRealAudioFact]` / `[DesktopRealAudioTheory]` attributes skip cleanly.

### `VoxFlow.Desktop.UiTests` — real `.app` automation

This suite is **excluded from CI** because it needs a real Mac Catalyst bundle, a user session, and AppleScript-driven UI automation. Use it when you change UI flows.

```bash
./scripts/run-desktop-ui-tests.sh
```

See [`docs/runbooks/desktop-ui-automation.md`](../runbooks/desktop-ui-automation.md) for the full setup (accessibility permissions, headless display modes, screenshot artifacts).

### Solution-wide

For a faster "did I break Desktop" check before pushing:

```bash
dotnet test VoxFlow.sln --no-restore
```

This runs Core, CLI, MCP, and Desktop in one go. Expected pre-PR baseline: every project at `Failed: 0`; Core/CLI/MCP at `Skipped: 0`; Desktop at `Skipped: 2` (the documented bundle baseline).

## Related

- [Developer Setup](./setup.md) — general SDK / dependencies / configuration model.
- [macOS Packaging](../deployment/macos-packaging.md) — building distributable `.app` and `.pkg`.
- [Desktop UI Automation](../runbooks/desktop-ui-automation.md) — running the real-app UI test suite.
- [Troubleshooting](../runbooks/troubleshooting.md) — runtime issues including Desktop-specific items.
- [Error catalog](../runbooks/error-catalog.md) — every user-facing error with remediation.
