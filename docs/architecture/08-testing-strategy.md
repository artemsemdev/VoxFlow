# Testing Strategy

> How VoxFlow is tested across all hosts, including test infrastructure, coverage layers, and automation approach.

Implementation snapshot: 2026-06-25.

## Test Pyramid

| Layer | Projects | Default Automation | Execution Speed |
|-------|----------|--------------------|-----------------|
| Unit / fast | VoxFlow.Core.Tests, VoxFlow.McpServer.Tests, CLI argument/progress tests, Desktop config/CLI-support tests | GitHub Actions + local | Seconds |
| Component / medium | VoxFlow.Desktop.Tests (headless Blazor component rendering and ViewModel tests) | GitHub Actions macOS job + local | Seconds to minutes |
| End-to-end / slow | VoxFlow.Cli.Tests, VoxFlow.Desktop.UiTests | CLI tests in GitHub Actions; real Desktop UI automation local/manual | Minutes |
| Environment-gated | RequiresPython speaker-labeling tests, Desktop real-audio tests | Local/manual unless explicitly enabled | Minutes to longer |

The repository currently has five test projects and about 500 xUnit test declarations. The exact runtime case count varies because `[Theory]` data rows expand at execution time.

## Test Projects

| Project | Scope | What is tested |
|---------|-------|----------------|
| `tests/VoxFlow.Core.Tests` | Core unit and integration | Configuration validation, startup validation, WAV parsing, transcript filtering, language selection, output formatting, file discovery, batch summary, DI registration |
| `tests/VoxFlow.Cli.Tests` | CLI end-to-end | Full application launch, startup validation, batch processing — all via process execution |
| `tests/VoxFlow.McpServer.Tests` | MCP unit and integration | Path policy validation, MCP configuration loading, Core model integration, tool dependency resolution |
| `tests/VoxFlow.Desktop.Tests` | Desktop component and integration | AppViewModel state machine, Desktop configuration merging, CLI support utilities, headless Blazor component rendering |
| `tests/VoxFlow.Desktop.UiTests` | Real macOS UI automation | App launch, file selection via native Open dialog, transcription happy path, failure recovery, clipboard integration |

## Frameworks and Tooling

| Concern | Choice | Notes |
|---------|--------|-------|
| Test framework | xUnit 2.9.2 | Exclusively; no MSTest or NUnit |
| Test SDK | Microsoft.NET.Test.Sdk 17.12.0 | Standard .NET test host |
| Conditional skips | Xunit.SkippableFact 1.4.13 | Used for environment-gated Python, bundle, and real-audio tests |
| Mocking | Custom stubs and fakes | No Moq, NSubstitute, or similar libraries |
| Blazor component testing | Custom `TestRenderer` | Similar to bUnit but hand-rolled; extends `Microsoft.AspNetCore.Components.RenderTree.Renderer` |
| Desktop UI automation | AppleScript via macOS Accessibility | Custom bridge; no Appium or XCTest |
| CI | GitHub Actions | `.github/workflows/ci.yml` runs standard validation; `.github/workflows/codeql.yml` runs CodeQL |

## Test Double Strategy

VoxFlow uses explicit, hand-crafted test doubles instead of mocking frameworks. Three patterns are used:

### Stub / Fake Services

Return canned responses for a specific test scenario. Used when the test needs a predictable collaborator.

- `StubConfigurationService` — returns a preset `TranscriptionOptions`
- `StubValidationService` — returns a preset `ValidationResult`
- `StubTranscriptionService` — returns a preset `TranscribeFileResult`
- `StubAudioConversionService` — returns a preset conversion result
- `FakeFfmpegFactory` — creates a shell script that copies a pre-prepared WAV file instead of running real ffmpeg

### Delegate Services

Accept lambdas for behavior, enabling inline test customization without separate stub classes.

- `DelegateConfigurationService` — delegates `LoadAsync` to a provided function
- `DelegateValidationService` — delegates `ValidateAsync` to a provided function
- `DelegateTranscriptionService` — delegates `TranscribeFileAsync` to a provided function

### Recording Services

Capture interactions for assertion. Used when the test needs to verify that a service was called with the right arguments.

- `RecordingFileDiscoveryService` — records discovered file lists
- `RecordingOutputWriter` — records written output
- `RecordingBatchSummaryWriter` — records summary content
- `RecordingResultActionService` — records clipboard and Finder calls
- `RecordingJsRuntime` — records JavaScript interop invocations

## Shared Test Infrastructure

Test support utilities live in `tests/TestSupport/` and are linked into each test project via `<Compile Include>` directives — not distributed as a NuGet package.

| Utility | Purpose |
|---------|---------|
| `FakeFfmpegFactory` | Creates a bash script that produces valid WAV output without real audio processing |
| `TestWaveFileFactory` | Generates PCM16 mono WAV files programmatically for deterministic audio input |
| `TestSettingsFileFactory` | Generates `appsettings.json` files with customizable transcription, batch, language, and filter settings |
| `TestProcessRunner` | Manages subprocess execution via `dotnet run` with timeout support and output monitoring |
| `TestProjectPaths` | Locates repository root and project paths by searching upward from the test assembly directory |

## Test Categories by Technique

### Pure Function Tests

Modules with no I/O dependencies are tested as pure functions:

- `TranscriptionFilter.FilterSegments` — segment acceptance rules
- `DecideWinningCandidate` — language selection scoring
- `OutputWriter.BuildOutputText` — transcript formatting
- `BatchSummaryWriter.BuildSummaryText` — batch report formatting
- `ValidationResult` construction — check aggregation

### File System Tests

Modules that interact with the file system use temporary directories:

- `TranscriptionOptions.LoadFromPath` — generated temp settings files via `TestSettingsFileFactory`
- `ValidationService.ValidateAsync` — temp directories for file system probes
- `FileDiscoveryService.DiscoverInputFiles` — temp directories with test files
- `WavAudioLoader.LoadSamplesAsync` — generated WAV fixtures via `TestWaveFileFactory`

### Process Execution Tests

CLI end-to-end tests launch the actual application as a child process:

- `ApplicationEndToEndTests` — launches `VoxFlow.Cli` via `dotnet run`, verifies exit codes and output
- `BatchProcessingEndToEndTests` — runs full batch pipeline with fake ffmpeg and temp directories
- `CliTestProcessRunner` — specialization of `TestProcessRunner` for CLI project paths

### Blazor Component Tests

Desktop UI components are tested via a custom headless renderer:

- `DesktopUiTestContext.Create()` sets up a DI container with stubbed/delegate services
- `TestRenderer` manages Blazor component lifecycle without a browser
- Tests verify: component visibility per state, validation banner rendering, action button behavior, progress display, error message surfacing
- Parallelization is disabled at assembly level to avoid UI state conflicts

### Real UI Automation Tests

The Desktop UI test suite drives the actual macOS `.app` bundle:

- `MacUiAutomation` executes AppleScript commands via macOS Accessibility (System Events)
- `DesktopAppLauncher` spawns the app via `open -n` and manages process lifecycle
- `VoxFlowDesktopApp` provides a page-object abstraction (`WaitForReadyAsync`, `BrowseFileAsync`, `Complete.CopyTranscriptAsync`)
- `DesktopUiTestSession` orchestrates the full test lifecycle: config scoping, app launch, test execution, cleanup
- Requires `VOXFLOW_RUN_DESKTOP_UI_TESTS=1` environment variable
- Diagnostics on failure: screenshot, accessibility snapshot, process log

## Conditional Test Execution

Tests that require external dependencies or special environments are gated by custom attributes and environment variables:

| Attribute | Environment Variable | When Used |
|-----------|---------------------|-----------|
| `[Trait("Category", "RequiresPython")]` | Python/pyannote runtime and model access | Speaker-labeling sidecar integration tests; excluded from default CI with `--filter "Category!=RequiresPython"` |
| `[DesktopUiFact]` | `VOXFLOW_RUN_DESKTOP_UI_TESTS=1` | Real macOS UI automation (requires `.app` bundle, Accessibility permission) |
| `[DesktopRealAudioFact]` / `[DesktopRealAudioTheory]` | `VOXFLOW_RUN_DESKTOP_REAL_AUDIO_TESTS=1` | Tests requiring model and audio fixtures in `models/` and `artifacts/Input/` |

Tests without these attributes run with no external dependencies — all fixtures are generated in-process.

## CI and Automation

The standard CI workflow is `.github/workflows/ci.yml`. It runs on pushes to `main`/`master` and on pull requests.

| Job | Runner | What it validates |
|-----|--------|-------------------|
| `core-hosts` (`Core, CLI, MCP`) | `ubuntu-latest` | Restores and builds Core, CLI, and MCP projects; runs Core tests with `Category!=RequiresPython`, plus CLI and MCP test projects; enforces an expected skipped-test count of 0 |
| `desktop` (`Desktop`) | `macos-latest` | Installs the MAUI Mac Catalyst workload; restores CLI, Desktop, and Desktop tests; builds Desktop for `net9.0-maccatalyst`; runs the headless Desktop test suite; enforces the current expected skipped-test count of 2 for bundle-dependent tests |

The real Desktop UI automation suite (`tests/VoxFlow.Desktop.UiTests`) is intentionally excluded from default CI. It requires a real macOS app bundle plus Accessibility permissions, so it remains a local/manual validation path through `./scripts/run-desktop-ui-tests.sh`.

CodeQL is configured separately in `.github/workflows/codeql.yml`. It runs on push, pull request, and weekly schedule. Current CodeQL analysis builds Core, CLI, and MCP on Ubuntu; Desktop CodeQL coverage is not part of the workflow yet and is tracked separately.

## What Each Test Layer Catches

| Layer | Catches | Does not catch |
|-------|---------|----------------|
| Core unit tests | Logic errors in filtering, scoring, formatting, configuration parsing, DI wiring | External process failures, native runtime issues |
| CLI end-to-end | Process startup, exit code mapping, config resolution, validation flow | Desktop-specific behavior, MCP protocol |
| MCP tests | Path policy violations, config binding, tool dependency resolution | Actual transcription via MCP, stdio protocol framing |
| Desktop component tests | ViewModel state transitions, view rendering per state, action dispatch | Real MAUI rendering, native drag-and-drop, platform integration |
| Desktop UI automation | Full user workflow against real app, native dialog interaction, clipboard | Headless/CI execution (requires macOS with Accessibility) |

## Trade-offs

- **No mocking framework** — explicit stubs are more verbose but more readable and debuggable. Acceptable given the codebase size.
- **Custom Blazor renderer** — avoids a bUnit dependency. Acceptable because the component testing needs are narrow (state-driven view switching, not complex interaction patterns).
- **AppleScript UI automation** — platform-specific and fragile compared to XCTest, but works without Xcode project setup and tests the real app bundle. Acceptable for a macOS-only Desktop host.
- **Default CI excludes expensive local-first scenarios** - the normal pull-request workflow covers Core, CLI, MCP, and headless Desktop validation, but not pyannote-backed integration tests, real Desktop UI automation, long-form audio, or release packaging smoke checks. Those remain explicit local/manual validation paths until a separate full-validation workflow exists.
