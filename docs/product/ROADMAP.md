# VoxFlow Roadmap

## Purpose

This roadmap is the delivery plan for the current repository state as of March 28, 2026.

It is not a PRD rewrite. It is an execution sequence for a solo developer working in this codebase:

- `src/VoxFlow.Core`
- `src/VoxFlow.Cli`
- `src/VoxFlow.Desktop`
- `src/VoxFlow.McpServer`
- `tests/*`

The roadmap is based on:

- `docs/product/PRD.md`
- `docs/product/DESKTOP_UI_SPEC.md`
- `ARCHITECTURE.md`
- `SETUP.md`
- the current Desktop implementation and test suites in the repository

## Current Baseline

- The shared Core, CLI, Desktop, and MCP hosts already exist.
- The Desktop app is already implemented as a macOS MAUI Blazor Hybrid app with `Ready`, `Running`, `Failed`, and `Complete` workflow states.
- The immediate problem is not "build Desktop from scratch." The immediate problem is to finish and stabilize the current Desktop UI contract, then lock it down with stronger tests.

Repository state checked on March 28, 2026:

- `tests/VoxFlow.Desktop.Tests` passes as the main fast Desktop suite.
- `tests/VoxFlow.Desktop.UiTests` already has real macOS automation coverage for launch, happy path, copy, failure recovery, and repeated use.
- Verified locally on March 28, 2026:
  - `dotnet test tests/VoxFlow.Desktop.Tests/VoxFlow.Desktop.Tests.csproj` -> `46 passed`, `2 skipped`
  - `./scripts/run-desktop-ui-tests.sh --filter AppStartsSuccessfully_AndReadyScreenIsVisible` -> passed
  - `./scripts/run-desktop-ui-tests.sh --filter HappyPath_UserSelectsFile_SeesRunningState_AndGetsResult` -> passed
- `docs/product/DESKTOP_UI_SPEC.md` is the most accurate statement of the remaining Desktop UI gaps and acceptance criteria.
- Some summary documentation is partially stale relative to the current test baseline. That should be corrected after the UI and test contract is stabilized, not before.

## Delivery Rules

- First finish the existing single-file Desktop workflow. Do not start new Desktop feature surfaces before that is stable.
- Prefer fixes in `src/VoxFlow.Desktop`. Only change `VoxFlow.Core` when the Desktop contract cannot be met at the host layer.
- Keep CLI and MCP behavior stable while Desktop work is in flight.
- Keep the fast Desktop test suite green at all times.
- Use real macOS UI automation as a release gate, not as the only safety net.

## Priority 1: Implement And Stabilize The Desktop App UI

This is the immediate delivery priority.

The work here should be driven by the known gaps and acceptance criteria in `docs/product/DESKTOP_UI_SPEC.md`, not by net-new feature ideas.

### 1.1 Ready Screen Contract

Fix the current Ready-screen copy and intake behavior so it matches the actual product:

- Update `src/VoxFlow.Desktop/Components/Pages/ReadyView.razor`.
- Update `src/VoxFlow.Desktop/Components/Shared/DropZone.razor`.
- Remove misleading `upload` language.
- Remove misleading `multiple files` language.
- Stop claiming only `M4A` if the runtime accepts a broader audio-file set.
- Mention drag-and-drop only when that runtime path is actually supported and enforced.

### 1.2 File Intake Gating

Make sure transcription can start only from a valid Ready state:

- Enforce Ready-state gating in `src/VoxFlow.Desktop/ViewModels/AppViewModel.cs`.
- Enforce the same gating in `src/VoxFlow.Desktop/MainPage.xaml.cs` so shell-level drag-and-drop cannot bypass blocked startup validation or non-ready screens.
- Reject unsupported or invalid intake before entering `Running`.
- Prevent stale result/progress/error state from surviving into the next run.
- Clear transient state on cancellation as well as on new-run start.

### 1.3 Running Screen Truthfulness

Bring the Running screen up to the UI spec:

- Update `src/VoxFlow.Desktop/Components/Pages/RunningView.razor`.
- Add a user-visible numeric percent.
- Add accessible `progressbar` semantics.
- Map `ProgressStage` values to readable labels instead of raw enum names.
- Show a truthful "starting" state before the first progress event arrives.
- Keep the displayed file name and progress state tied to the current run only.

### 1.4 Complete And Failed Screen Hardening

Normalize the end-of-run experience across Apple Silicon and Intel CLI-bridge execution:

- Update `src/VoxFlow.Desktop/Components/Pages/CompleteView.razor`.
- Update `src/VoxFlow.Desktop/Components/Pages/FailedView.razor` if needed for clearer recovery behavior.
- Normalize transcript preview behavior across in-process and CLI-bridge paths.
- Make `Copy Transcript` copy the full transcript when available, not just `TranscriptPreview`.
- Surface preview truncation or preview-unavailable states honestly.
- Disable or hide `Open Folder` and copy actions when required data is missing.
- Surface clipboard failures and folder-opening failures as visible non-fatal UI feedback.
- Surface startup warnings on the Ready screen when startup validation has warnings but does not block execution.

### 1.5 Automation Contract Stability

Keep the UI testable while the UI is being corrected:

- Preserve stable ids already used by the Desktop tests.
- Extend `src/VoxFlow.Desktop/Automation/DesktopUiAutomationHost.cs` so automation can observe critical screens and messages, not only the current button subset.
- Keep `docs/product/DESKTOP_UI_SPEC.md` section 21 as the selector contract of record.

### Exit Criteria For Priority 1

- The current Desktop UI matches the actual single-file local workflow described in the PRD and UI spec.
- No file-intake path can bypass blocked startup validation or non-ready workflow state.
- The user-visible Ready, Running, Failed, and Complete states behave consistently on both Desktop execution paths:
  - Apple Silicon in-process transcription
  - Intel Mac Catalyst CLI-bridge transcription
- The remaining known Desktop UI gaps are either closed or explicitly deferred with a written reason.

## Priority 2: Create Detailed Test Coverage For The Desktop UI

This is the second immediate delivery priority.

Once the UI contract is corrected, the next job is to make regressions expensive and visible.

### 2.1 Expand Fast Desktop Tests

Strengthen the fast local safety net in `tests/VoxFlow.Desktop.Tests`:

- Add more `AppViewModel` tests for run gating, transient-state clearing, cancellation cleanup, and warning handling.
- Expand `DesktopUiComponentTests` for:
  - corrected Ready copy
  - blocked intake behavior
  - progressbar semantics
  - numeric progress rendering
  - human-readable stage labels
  - missing preview state
  - missing result-path state
  - copy and folder-action failure messages
  - full-transcript copy behavior
- Add tests around shell-path bypass prevention where practical.

### 2.2 Expand Real macOS UI Automation

Use `tests/VoxFlow.Desktop.UiTests` and `scripts/run-desktop-ui-tests.sh` to cover the missing real-app workflows:

- startup fatal error and retry
- Ready Blocked with disabled intake
- cancellation during Running
- failure retry
- Choose Different File recovery
- missing result metadata states
- copy failure handling
- folder-open failure handling
- drag-and-drop only if that path is made truthful and stable on the supported runtime

The real UI suite should stay scenario-based and high-signal. Do not turn it into a huge slow matrix when the same behavior can be covered faster in headless tests.

### 2.3 Make The Test Gate Explicit

Adopt a simple test pyramid for Desktop work:

1. Fast gate:
   - `dotnet test tests/VoxFlow.Desktop.Tests/VoxFlow.Desktop.Tests.csproj`
2. Real UI release gate:
   - `./scripts/run-desktop-ui-tests.sh --filter AppStartsSuccessfully_AndReadyScreenIsVisible`
   - `./scripts/run-desktop-ui-tests.sh --filter HappyPath_UserSelectsFile_SeesRunningState_AndGetsResult`
   - additional targeted filters for new failure, blocked, and cancel scenarios

### Exit Criteria For Priority 2

- Every user-visible Desktop state has direct test coverage.
- Every primary Desktop action has both a defined selector contract and a regression test.
- The real UI suite covers more than launch and browse-based happy path.
- Desktop regressions are caught first in `tests/VoxFlow.Desktop.Tests`, then confirmed end-to-end in `tests/VoxFlow.Desktop.UiTests`.

## Priority 3: Align Documentation And Release Readiness

Only after the Desktop UI and Desktop UI tests are stable:

- update `README.md` so Desktop claims match the actual passing coverage
- update `ARCHITECTURE.md` where Desktop verification notes are stale
- update `SETUP.md` so Desktop test instructions and current baseline stay accurate
- keep `docs/product/DESKTOP_UI_SPEC.md` as the Desktop contract and remove closed items from its known-gap list
- verify `scripts/build-macos.sh` still produces the expected macOS artifact after the UI changes

### Exit Criteria For Priority 3

- Repository docs no longer disagree about current Desktop status.
- A new developer can build, test, and package the Desktop app using the checked-in documentation only.

## Priority 4: Resume Broader Product Hardening Only After Desktop Is Stable

After Priorities 1 through 3 are complete, resume targeted work across the rest of the repo:

- Desktop-driven Core cleanup where the UI exposed real contract gaps
- CLI and MCP hardening that preserves the shared Core contract
- operational polish for packaging and local setup

This is intentionally later work. The repository already has working CLI, Core, MCP, and a mostly working Desktop flow. The current delivery risk is Desktop UI correctness and Desktop UI regression coverage.

## Deferred Until After The Desktop Priorities

These are not current roadmap priorities for this repository:

- batch-processing UI in Desktop
- Desktop settings editor UI
- Windows or Linux desktop support
- real-time transcription
- speaker diarization
- translation
- remote or HTTP/SSE MCP transport
- multi-file Desktop workflow

## Main Risks And Dependencies

- Intel Mac Catalyst and Apple Silicon do not share the exact same Desktop transcription path. UI behavior must stay aligned across both.
- Drag-and-drop is currently the highest-risk Desktop input path because support differs by runtime and shell layer.
- Real UI automation is macOS-only and opt-in. Keep it focused on the highest-value scenarios.
- Documentation drift is already visible. Treat `docs/product/DESKTOP_UI_SPEC.md` as the detailed Desktop backlog of record until the repo docs are reconciled.
