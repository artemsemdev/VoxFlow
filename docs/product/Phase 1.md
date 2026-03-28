# VoxFlow Phase 1: Desktop Stabilization

## Phase Goal

Ship a stable, demoable macOS Desktop single-file transcription workflow and back it with enough test coverage that ongoing delivery can stay disciplined.

This phase intentionally does not try to finish the entire PRD. It focuses on the most visible execution path in the current repository:

- Desktop launch and startup validation handling
- single-file intake and Ready-state gating
- running progress with truthful status
- failure, cancel, and recovery flows
- result review and result actions

This phase addresses PRD functional requirements FR-11 (Desktop Application) and FR-12 (Desktop Platform Compatibility), and contributes to the Desktop-specific PRD success metrics in section 14.

## Why This Is Phase 1

The repository already has:

- a shared Core transcription pipeline (FR-01 through FR-09)
- a working CLI for single-file and batch processing
- MCP Server with tools, prompts, and path safety (FR-10)
- a Desktop app with real UI automation covering launch and happy path

The immediate delivery gap is not foundational engineering. It is product-surface closure:

- finish the Desktop UI contract per the [Desktop UI Specification](DESKTOP_UI_SPEC.md)
- make Desktop behavior safe and truthful across both runtime paths (Apple Silicon and Intel Mac Catalyst)
- close the 21 known implementation gaps documented in the UI spec (section 22)
- create enough test coverage that regressions are expensive and visible

## Phase 1 Scope

**In scope:**

- Desktop UI contract fixes from the [Desktop UI Specification](DESKTOP_UI_SPEC.md) known gaps (section 22)
- Desktop state-management hardening (transient state clearing, Ready-state gating)
- Desktop fast tests in `tests/VoxFlow.Desktop.Tests`
- Desktop real macOS UI automation in `tests/VoxFlow.Desktop.UiTests`
- Enough documentation alignment to support iterative shipping

**Out of scope:**

- Desktop batch UI (batch processing exists in the pipeline but Desktop is single-file per PRD FR-11)
- Desktop settings editor (configuration overrides remain file-based per PRD section 7)
- Windows or Linux desktop support (deferred per PRD section 7)
- New MCP features
- CLI feature expansion
- Notarized release pipeline
- New Core pipeline features

## Phase 1 Success Criteria

These criteria map to PRD success metrics (section 14):

- Desktop Ready, Running, Failed, and Complete states behave consistently and truthfully
- No file-intake path can bypass blocked startup validation or invalid workflow state
- Transcript preview and copy behavior are honest and consistent across Apple Silicon and Intel Mac Catalyst
- Progress reporting shows truthful stage labels, numeric percentage, and accessible progressbar semantics
- The fast Desktop suite covers the corrected behavior
- The real macOS UI suite covers more than launch and happy path
- The repository has a clear first-wave GitHub backlog and release gate

## Phase 1 Workstreams

### Workstream A: Desktop UI Contract

**Target outcome:** The Desktop app matches the actual single-file local workflow documented in the PRD (FR-11) and the [Desktop UI Specification](DESKTOP_UI_SPEC.md).

**Deliverables:**

- Corrected Ready-screen copy (remove M4A-only and upload claims, UI spec section 11 and 17)
- Guarded file intake (Ready-state gating at both ViewModel and shell layers, UI spec sections 12.9 and 9.4)
- Cleaned-up run transitions (transient state clearing, UI spec section 9.5)
- Improved Running progress semantics (numeric percent, human-readable labels, progressbar a11y, UI spec section 13)
- Hardened Complete-screen actions (full-transcript copy, preview truncation, action error handling, UI spec section 15)
- Hardened Failed-screen recovery (clear state transitions, UI spec section 14)
- Non-blocking startup warning visibility (UI spec section 11.6)

**Addresses UI spec known gaps:** 1-18

### Workstream B: Desktop Test Gate

**Target outcome:** Desktop regressions are caught early and visibly through a test pyramid.

**Deliverables:**

- Expanded ViewModel and component tests in `tests/VoxFlow.Desktop.Tests`
- Expanded real macOS UI automation in `tests/VoxFlow.Desktop.UiTests`
- Updated automation bridge with broader element tracking
- Stable automation IDs preserved per UI spec section 21

**Addresses UI spec known gaps:** 19-21

### Workstream C: Operational Clarity

**Target outcome:** A solo developer can build, test, and demo the active product without reading the entire repository.

**Deliverables:**

- Explicit smoke routine for all active hosts (CLI, Desktop, MCP)
- Status docs aligned with the actual repository state
- Manual demo-release checklist for macOS packaging

## Phase 1 Issue Set

### Workstream A Issues

#### A1. Correct Ready-screen copy and capability messaging

Fix misleading copy in `ReadyView.razor` and `DropZone.razor`.

Current problems (UI spec gaps 1, 2, 3):
- ReadyView says "Drop your M4A files here to convert speech into text"
- DropZone says "Drop your M4A files here or browse from your device"
- Footer says "Supported format: M4A. You can upload multiple files."
- The runtime accepts 10+ audio formats, not just M4A
- "upload" implies network transfer in a local-first product
- "multiple files" contradicts the single-file Desktop scope
- Drag-and-drop is advertised even when it is not available on the current runtime

Acceptance criteria:
- Ready-screen describes one local audio file
- No "upload" or "multiple files" claims remain
- Drag-and-drop wording is runtime-aware
- Format claims match actual supported types

#### A2. Enforce Ready-state start guard in AppViewModel

Fix the ViewModel to prevent transcription from starting outside the Ready Available state (UI spec gap 5).

Acceptance criteria:
- Blocked validation cannot start a run
- Invalid workflow states (Running, Failed, Complete) cannot start a run
- Tests cover the guard

#### A3. Make shell-level drag-and-drop obey the Ready-state contract

Fix `MainPage.xaml.cs` to enforce the same state gating as the Razor UI (UI spec gaps 4, 5).

Acceptance criteria:
- Native drop cannot bypass blocked Ready
- Native drop cannot start a run outside Ready Available
- Unsupported dropped files are rejected before entering Running

#### A4. Clear transient Desktop state on new run, retry, and cancel

Fix stale state issues in `AppViewModel.TranscribeFileAsync()` and the cancellation path (UI spec gaps 6, 7).

Current problems:
- `TranscribeFileAsync()` does not clear `TranscriptionResult` or `CurrentProgress` at run start
- The cancellation path sets `CurrentState = Ready` directly instead of calling `GoToReady()`, leaving `CurrentProgress` stale

Acceptance criteria:
- New runs start with cleared progress and result state
- Cancel returns to a clean Ready state with no stale data
- Retries do not leak stale state from the previous run

#### A5. Improve Running-screen progress semantics and labels

Bring `RunningView.razor` up to the UI spec (UI spec gaps 8, 9, 10).

Current problems:
- Percent is used only as CSS width, not as visible text
- Stage labels render raw enum names like `LoadingModel`
- Before the first progress event, only a spinner is shown with no text

Acceptance criteria:
- Numeric percent is visible as text alongside the progress bar
- Stage labels are human-readable (e.g., "Loading model" not "LoadingModel")
- Progressbar exposes `role="progressbar"` and `aria-valuenow` semantics
- A truthful "Starting transcription..." state is visible before the first progress event

#### A6. Normalize preview and full-transcript copy behavior

Fix `CompleteView.razor` to handle preview and copy correctly (UI spec gaps 12, 13, 14).

Current problems:
- Preview truncation is not surfaced to the user
- "Copy Transcript" copies `TranscriptPreview` (partial), not the full transcript
- Preview behavior differs between Apple Silicon (in-process) and Intel (CLI bridge) paths

Acceptance criteria:
- Preview rules are consistent across Desktop runtime paths
- Full transcript is copied when available
- Preview truncation or preview-unavailable state is explicit in the UI

#### A7. Surface startup warnings and non-fatal Complete-screen action errors

Fix missing feedback in ReadyView and CompleteView (UI spec gaps 11, 15, 16, 17).

Current problems:
- Non-blocking startup warnings are not shown when `CanStart == true` but `HasWarnings == true`
- Open Folder and Copy Text buttons are always shown even when data is missing
- Clipboard failures are not surfaced to the user
- Folder-opening failures are not surfaced to the user

Acceptance criteria:
- Non-blocking startup warnings are visible on the Ready screen
- Missing result metadata disables or hides invalid actions
- Copy and open-folder failures remain non-fatal but are visible to the user

### Workstream B Issues

#### B1. Expand fast Desktop tests for the updated UI contract

Add ViewModel and component tests in `tests/VoxFlow.Desktop.Tests` covering the behavior fixed in Workstream A.

Acceptance criteria:
- ViewModel tests cover: start-guard, transient-state clearing, cancellation cleanup, warning handling
- Component tests cover: corrected Ready copy, blocked intake, progressbar semantics, numeric percent, human-readable stage labels, missing preview, missing result path, copy/folder action failures, full-transcript copy

#### B2. Extend the Desktop automation bridge tracked IDs

Update `DesktopUiAutomationHost.cs` to expose startup error screen, validation message visibility, and other critical elements (UI spec gap 20).

Acceptance criteria:
- Startup error and validation-message visibility are exposed to the UI automation suite
- Existing automation scenarios keep passing

#### B3. Add real UI scenario for startup failure and blocked-ready

Add macOS UI automation coverage for non-happy-path startup states (UI spec gap 21).

Acceptance criteria:
- One real UI scenario covers startup fatal error and retry
- One real UI scenario covers Ready Blocked with disabled intake

#### B4. Add real UI scenario for cancel and failure recovery

Add macOS UI automation coverage for cancel and failure flows (UI spec gap 21).

Acceptance criteria:
- Cancel during Running returns to Ready without stale state
- Failure recovery via retry and choose-different-file remain green end-to-end

### Workstream C Issues

#### C1. Document the local config and smoke workflow for all active hosts

Ensure all three hosts (CLI, Desktop, MCP) have explicit launch and smoke-test instructions.

Acceptance criteria:
- Desktop, CLI, and MCP launch contracts are explicit
- One recommended smoke routine exists for each host

#### C2. Align status docs with the actual repository state

Update documentation that disagrees about current Desktop status.

Acceptance criteria:
- README, SETUP, and ARCHITECTURE notes no longer disagree about Desktop state
- The Desktop UI spec known-gap list (section 22) reflects which gaps were closed

#### C3. Create a demo-ready macOS release checklist

Document the steps to build, smoke, package, and verify a Desktop release.

Acceptance criteria:
- Build, smoke, package, and verification steps are documented
- Known release gaps are called out explicitly

## Suggested PR Sequence

The following sequence keeps each PR individually reviewable and shippable. A solo developer may batch adjacent items when the changes are small and cohesive (e.g., A2+A3 both address intake gating).

| PR | Issue | Summary |
|---|---|---|
| 1 | A1 | Ready-screen copy cleanup |
| 2 | A2 + A3 | ViewModel start guard and shell-level DnD guard |
| 3 | A4 | Transient state cleanup on run start, retry, and cancel |
| 4 | A5 | Running-screen progress improvements |
| 5 | A6 | Preview and copy normalization |
| 6 | A7 | Startup warnings and non-fatal action errors |
| 7 | B1 | Fast-test expansion for Workstream A changes |
| 8 | B2 | Automation bridge update |
| 9 | B3 + B4 | Real UI scenarios for startup/blocked/cancel/failure |
| 10 | C1 | Local smoke workflow docs |
| 11 | C2 + C3 | Status-doc alignment and demo-release checklist |

Total: 11 PRs. Issues A2+A3 and B3+B4 are batched because they share context and are more natural as single reviews. C2+C3 are batched because they are both documentation.

Tests in B1 may also be interleaved with the A-series PRs when the developer prefers to ship tests alongside the fixes. The sequence above separates them for clarity but does not require strict ordering.

## Phase 1 Release Gate

Minimum verification before calling Phase 1 complete:

```bash
# Fast gate
dotnet test tests/VoxFlow.Desktop.Tests/VoxFlow.Desktop.Tests.csproj

# Real UI release gate
./scripts/run-desktop-ui-tests.sh --filter AppStartsSuccessfully_AndReadyScreenIsVisible
./scripts/run-desktop-ui-tests.sh --filter HappyPath_UserSelectsFile_SeesRunningState_AndGetsResult

# New scenarios from B3 + B4
./scripts/run-desktop-ui-tests.sh --filter StartupBlockedReady
./scripts/run-desktop-ui-tests.sh --filter CancelDuringRunning
./scripts/run-desktop-ui-tests.sh --filter FailureRecovery
```

All five gates must pass on the developer's macOS machine before Phase 1 is declared complete.

## After Phase 1

Only after Phase 1 is complete should the active roadmap move to:

- broader cross-host polish (Roadmap Priority 4)
- packaging and release maturity
- post-Phase-1 scope such as Desktop batch UI or settings UI (PRD section 7 non-goals for current phase)

Phase 2 planning should start from the updated UI spec known-gap list and any new issues discovered during Phase 1 delivery.
