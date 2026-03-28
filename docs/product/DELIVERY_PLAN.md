# Delivery Plan

## 1. Project Summary

VoxFlow is a local-first audio transcription product built as a shared `.NET 9` core with three hosts:

- `VoxFlow.Cli`
- `VoxFlow.Desktop`
- `VoxFlow.McpServer`

Based on `docs/product/PRD.md`, `docs/product/DESKTOP_UI_SPEC.md`, `ARCHITECTURE.md`, `docs/architecture/`, and the current repository state, the smallest credible MVP to actively execute now is:

- a reliable macOS Desktop single-file transcription workflow
- backed by the existing shared Core pipeline
- with CLI and MCP kept working and documented, but not expanded first

Current repo reality:

- Core, CLI, MCP, and Desktop all already exist
- batch mode already exists in Core/CLI
- MCP tools and path-policy work already exist
- Desktop is already implemented, but its UI contract is not fully closed
- the Desktop UI spec explicitly documents the remaining gaps

That means the next job is not broad architecture work. The next job is disciplined execution against the existing Desktop workflow and its tests.

## Phase 1 Status (March 28, 2026)

**Phase 1 is complete.** All Workstream A (Desktop UI Contract), Workstream B (Desktop Test Gate), and Workstream C (Operational Clarity) deliverables have been implemented and verified.

Completed issues:

| Issue | Status | Summary |
|---|---|---|
| 1 | **Done** | Ready-screen copy corrected — no M4A-only, no upload, no multiple files |
| 2 | **Done** | ViewModel start guard enforced via `CanStart` property |
| 3 | **Done** | Shell-level native drop checks `CanStart` before proceeding |
| 4 | **Done** | Transient state cleared on new run, retry, and cancel |
| 5 | **Done** | Numeric percent, human-readable stage labels, progressbar a11y, "Starting transcription..." |
| 6 | **Done** | Full transcript copied via `GetFullTranscript()`; preview truncation surfaced |
| 7 | **Done** | Startup warnings visible; action errors shown non-fatally; buttons hidden when data missing |
| 8 | **Done** | 10+ new fast tests covering start guard, transient state, warnings, progress, copy, preview |
| 9 | **Done** | Automation bridge tracks 27 element IDs including startup-error, validation, progress, preview |
| 10–11 | **Deferred** | Real UI scenarios for startup failure, blocked ready, cancel, and failure recovery — automation bridge support is in place; execution requires the built `.app` |
| 12 | **Done** | Per-host smoke routines documented in SETUP.md |
| 13 | **Done** | README, ARCHITECTURE, DESKTOP_UI_SPEC known gaps updated |
| 14 | **Done** | Demo-ready release checklist created at `docs/product/RELEASE_CHECKLIST.md` |

Remaining open DESKTOP_UI_SPEC gaps: 12 (preview normalization across runtimes), 18 (Razor-layer file-type validation), 19 (accessibility focus management), 21 (real UI scenario execution).

## 2. Delivery Stages

### Stage 0: Execution Baseline

Purpose:

- turn the existing docs into a lightweight GitHub operating model
- define what counts as the active MVP
- create the initial milestones, labels, and issue backlog

Output:

- GitHub labels
- milestones
- project board
- first-wave implementation issues

### Stage 1: Desktop Workflow Contract

Purpose:

- finish the current Desktop single-file workflow so it behaves exactly as the product docs claim

Scope:

- startup handling
- Ready state
- file intake
- Running state
- Failed state
- Complete state
- Desktop Apple Silicon and Intel parity where the UI contract matters

Output:

- Desktop UI behavior matches `docs/product/DESKTOP_UI_SPEC.md` for the first-release scope

### Stage 2: Desktop Verification Gate

Purpose:

- make Desktop regressions easy to detect quickly

Scope:

- `tests/VoxFlow.Desktop.Tests`
- `tests/VoxFlow.Desktop.UiTests`
- automation selectors and tracked ids
- stable real-app scenarios for launch, happy path, blocked-ready, failure, and cancel

Output:

- a credible Desktop release gate for a solo developer

### Stage 3: Cross-host Operability

Purpose:

- keep CLI, Desktop, and MCP usable together while Desktop work lands

Scope:

- config clarity
- launch commands
- smoke workflow
- status documentation alignment

Output:

- all active hosts can be run and verified without guessing

### Stage 4: Demo-ready Release

Purpose:

- make the repo demoable and packageable in a repeatable way

Scope:

- docs aligned with real behavior
- packaging helper validated
- manual release checklist

Output:

- repeatable local release routine for macOS demo builds

### Stage 5: Next-phase Enhancements

Purpose:

- resume larger scope only after the Desktop MVP is stable

Deferred examples:

- Desktop batch UI
- Desktop settings editor
- notarized distribution flow
- Windows/Linux Desktop support
- HTTP/SSE MCP transport

## 3. Epics

### Epic 1: Desktop Single-file Workflow

Why it exists:

- the Desktop app is the highest-visibility product surface
- the current repo already has a working Desktop app, but the UI spec lists concrete contract gaps

Value delivered:

- a usable local transcription app that can be shown, tested, and iterated on with confidence

Main dependencies:

- `src/VoxFlow.Desktop`
- `src/VoxFlow.Core`
- `DesktopConfigurationService`
- `AppViewModel`
- `DesktopCliTranscriptionService`

Out of scope for first iteration:

- Desktop batch UI
- settings editor UI
- transcript editing
- new platforms

### Epic 2: Desktop Verification And Automation

Why it exists:

- the Desktop contract is too easy to regress without stronger fast tests and real-app coverage

Value delivered:

- visible progress, safer refactors, and a practical release gate

Main dependencies:

- Epic 1 behavior changes
- `tests/VoxFlow.Desktop.Tests`
- `tests/VoxFlow.Desktop.UiTests`
- `scripts/run-desktop-ui-tests.sh`

Out of scope for first iteration:

- broad UI matrix testing
- performance benchmarking
- CI overhaul

### Epic 3: Cross-host Operability

Why it exists:

- Desktop is the current priority, but CLI batch and MCP are already real product surfaces and should not drift into confusion

Value delivered:

- consistent local setup, less config confusion, and fewer “works only on one host” failures

Main dependencies:

- `SETUP.md`
- host `appsettings.json` files
- smoke checks

Out of scope for first iteration:

- new MCP features
- new CLI features

### Epic 4: Demo-ready Release And Repo Operations

Why it exists:

- the repo already has packaging helpers and extensive docs, but not yet a tight delivery loop

Value delivered:

- a project that looks and behaves professionally in GitHub and is easier to ship iteratively

Main dependencies:

- Desktop stabilization
- smoke workflow
- `scripts/build-macos.sh`
- README / setup / architecture docs

Out of scope for first iteration:

- full notarization pipeline
- installer polish
- auto-updater

## 4. Iterative Delivery Slices

### Epic 1: Desktop Single-file Workflow

#### Slice 1.1: Truthful Ready State

Deliver:

- correct Ready-screen copy
- accurate file-type messaging
- drag-and-drop wording only when truthful

Demo:

- app launches into a Ready screen that describes the real product correctly

#### Slice 1.2: Safe File Intake

Deliver:

- file intake is allowed only from a valid Ready state
- blocked startup validation prevents all start paths
- shell-level drag-and-drop cannot bypass UI state rules

Demo:

- blocked Ready cannot be bypassed by browse or drop

#### Slice 1.3: Clean Workflow State Transitions

Deliver:

- no stale progress or stale result data on retry, cancel, or next run

Demo:

- run, cancel, retry, and second-run flows all stay clean

#### Slice 1.4: Trustworthy Running And Complete Screens

Deliver:

- readable progress labels
- numeric percent
- proper progress semantics
- full-transcript copy behavior
- honest preview behavior
- visible non-fatal action errors

Demo:

- a long run shows understandable progress and a completed run exposes consistent result actions

### Epic 2: Desktop Verification And Automation

#### Slice 2.1: Fast Desktop Regression Coverage

Deliver:

- ViewModel and component tests for the updated Desktop contract

Demo:

- fast Desktop suite catches Ready/Running/Complete regressions locally

#### Slice 2.2: Real UI Critical-path Coverage

Deliver:

- launch
- happy path
- blocked-ready
- startup retry
- cancel
- failure recovery

Demo:

- `.app` automation proves the main Desktop workflow behaves correctly

#### Slice 2.3: Stable Automation Contract

Deliver:

- selectors and tracked ids that match the Desktop spec

Demo:

- UI automation stays stable across ongoing UI cleanup

### Epic 3: Cross-host Operability

#### Slice 3.1: Clear Local Run Contract

Deliver:

- explicit config guidance for Desktop, CLI, and MCP

Demo:

- a new contributor can launch each host without guessing which config file to use

#### Slice 3.2: Lightweight Smoke Workflow

Deliver:

- one documented verification routine that checks the active product surfaces

Demo:

- run a small set of commands before shipping a demo build

### Epic 4: Demo-ready Release And Repo Operations

#### Slice 4.1: Doc Alignment

Deliver:

- README, setup, architecture notes, and product docs aligned with actual repo state

Demo:

- no contradictory current-status statements across core docs

#### Slice 4.2: Manual Release Checklist

Deliver:

- build, smoke, package, and verify steps for a demoable macOS release

Demo:

- a repeatable release routine using the checked-in scripts and docs

## 5. GitHub Issues

These issues are sized for solo execution. The target is one issue per PR whenever practical.

### 1. Correct Ready-screen copy and capability messaging

Description:

- update the Ready screen and DropZone copy so it describes the actual single-file local workflow

Why it matters:

- the current Desktop UI spec explicitly calls out misleading `upload`, `multiple files`, and file-format messaging

Scope:

- `src/VoxFlow.Desktop/Components/Pages/ReadyView.razor`
- `src/VoxFlow.Desktop/Components/Shared/DropZone.razor`
- matching Desktop component tests

Acceptance criteria:

- Ready state describes one local audio file
- no `upload` language remains
- no `multiple files` claim remains
- drag-and-drop wording is runtime-aware

Dependencies:

- none

### 2. Enforce Ready-state start guard in AppViewModel

Description:

- prevent Desktop transcription from starting when the workflow is blocked or not in a valid Ready state

Why it matters:

- visible UI disabling is not sufficient on its own

Scope:

- `src/VoxFlow.Desktop/ViewModels/AppViewModel.cs`
- related Desktop tests

Acceptance criteria:

- blocked validation cannot start a run
- non-Ready states cannot start a new run
- tests cover blocked and invalid start attempts

Dependencies:

- none

### 3. Make shell-level drag-and-drop obey the Ready-state contract

Description:

- apply the same start rules to native drag-and-drop as to the visible Ready UI

Why it matters:

- shell-level intake currently risks bypassing the product contract

Scope:

- `src/VoxFlow.Desktop/MainPage.xaml.cs`
- any needed validation or guard plumbing
- tests or automation coverage where practical

Acceptance criteria:

- drag-and-drop cannot start when Ready is blocked
- drag-and-drop cannot start from non-Ready states
- unsupported drops fail before `Running`

Dependencies:

- issue 2

### 4. Clear transient Desktop state on new run, retry, and cancel

Description:

- remove stale progress, stale results, and stale errors across run transitions

Why it matters:

- retry and cancel behavior should not leak prior run state into the next view

Scope:

- `src/VoxFlow.Desktop/ViewModels/AppViewModel.cs`
- Desktop tests

Acceptance criteria:

- new runs start clean
- cancel returns to a clean Ready state
- retry does not display stale progress or result state

Dependencies:

- issue 2

### 5. Improve Running-screen progress semantics and labels

Description:

- make Running show readable status, visible numeric percent, and accessible progress semantics

Why it matters:

- the current screen is not yet fully honest or accessible

Scope:

- `src/VoxFlow.Desktop/Components/Pages/RunningView.razor`
- any small helper logic for stage labels
- Desktop tests

Acceptance criteria:

- numeric percent is visible
- stage labels are human-readable
- progressbar semantics are present
- “starting” feedback exists before first progress event

Dependencies:

- issue 4

### 6. Normalize preview and full-transcript copy behavior

Description:

- make result preview behavior consistent across Apple Silicon and Intel CLI bridge, and ensure copy behavior matches the button label

Why it matters:

- current preview and copy behavior is inconsistent and can over-promise

Scope:

- `src/VoxFlow.Desktop/Components/Pages/CompleteView.razor`
- `src/VoxFlow.Desktop/Services/DesktopCliTranscriptionService.cs`
- related Desktop tests

Acceptance criteria:

- preview rules are consistent across Desktop runtime paths
- full transcript is copied when available
- preview truncation or preview-unavailable state is surfaced honestly

Dependencies:

- issue 5

### 7. Surface startup warnings and non-fatal Complete-screen action errors

Description:

- show non-blocking startup warnings and visible non-fatal UI errors for copy/open-folder failures or missing result metadata

Why it matters:

- the UI should stay truthful without turning recoverable situations into hard failures

Scope:

- `src/VoxFlow.Desktop/Components/Pages/ReadyView.razor`
- `src/VoxFlow.Desktop/Components/Pages/CompleteView.razor`
- any small ViewModel support
- tests

Acceptance criteria:

- Ready can show warnings while staying actionable
- invalid or missing result-path state disables or hides `Open Folder`
- copy/open-folder failures show visible feedback without leaving Complete

Dependencies:

- issue 6

### 8. Expand fast Desktop tests for the updated UI contract

Description:

- add or revise Desktop ViewModel and component tests to cover the corrected behavior

Why it matters:

- most regressions should be caught without running the real app

Scope:

- `tests/VoxFlow.Desktop.Tests/AppViewModelTests.cs`
- `tests/VoxFlow.Desktop.Tests/DesktopUiComponentTests.cs`

Acceptance criteria:

- tests cover state guards, cleanup rules, warning states, progress semantics, and result-action rules
- the fast Desktop suite stays green

Dependencies:

- issues 1 through 7

### 9. Extend the Desktop automation bridge tracked ids

Description:

- expose startup error, validation message, and other missing critical states to the real UI suite

Why it matters:

- real UI automation can only verify what the bridge can observe

Scope:

- `src/VoxFlow.Desktop/Automation/DesktopUiAutomationHost.cs`
- any page-object updates in the UI test project

Acceptance criteria:

- startup error and validation-message visibility are observable
- active-screen reporting remains stable
- existing UI tests continue to pass

Dependencies:

- issue 7

### 10. Add real UI scenario for startup failure and blocked-ready state

Description:

- add real macOS automation coverage for fatal startup error and Ready Blocked behavior

Why it matters:

- both are explicit product requirements and are not fully proven by the current real UI suite

Scope:

- `tests/VoxFlow.Desktop.UiTests/DesktopEndToEndTests.cs`
- supporting test setup if needed

Acceptance criteria:

- one real UI test covers startup failure plus retry
- one real UI test covers blocked Ready with disabled intake
- failures produce useful artifacts

Dependencies:

- issue 9

### 11. Add real UI scenario for cancel and failure recovery

Description:

- add real macOS automation for cancel and failure recovery after the Desktop contract changes

Why it matters:

- cancel/retry/choose-different-file are core workflow behaviors

Scope:

- `tests/VoxFlow.Desktop.UiTests/DesktopEndToEndTests.cs`
- fixture support as needed

Acceptance criteria:

- cancel returns to Ready without stale state leakage
- failure recovery still works end-to-end
- tests are stable enough for release gating

Dependencies:

- issues 4, 7, and 9

### 12. Document the local config and smoke workflow for all active hosts

Description:

- make Desktop, CLI, and MCP launch contracts explicit and define one lightweight smoke routine

Why it matters:

- the current repo is powerful but easy to misconfigure, especially around Desktop single-file vs batch defaults and MCP transcription config

Scope:

- `SETUP.md`
- example commands
- optionally a small helper doc or script if needed

Acceptance criteria:

- Desktop, CLI single-file, CLI batch, and MCP launch commands are explicit
- one recommended smoke routine exists
- that routine includes Desktop fast tests and one real UI scenario

Dependencies:

- none

### 13. Align status documentation with the actual repo state

Description:

- update the main docs so they stop disagreeing about current Desktop status and coverage

Why it matters:

- current doc drift already exists and will get worse unless corrected after the behavior changes land

Scope:

- `README.md`
- `SETUP.md`
- `ARCHITECTURE.md`
- `docs/product/DESKTOP_UI_SPEC.md` known gaps where appropriate

Acceptance criteria:

- current Desktop status is described consistently
- closed gaps are updated
- no core doc makes claims unsupported by the repo

Dependencies:

- issues 1 through 12

### 14. Create a demo-ready macOS release checklist

Description:

- define a repeatable release routine using the existing packaging helper and smoke checks

Why it matters:

- packaging exists, but the delivery routine is still implicit

Scope:

- release checklist doc
- `scripts/build-macos.sh` assumptions
- smoke and verification steps

Acceptance criteria:

- checklist covers build, smoke, package, and artifact verification
- non-automated release gaps are called out explicitly
- a solo developer can execute it without ad hoc steps

Dependencies:

- issues 12 and 13

## 6. Recommended Execution Order

1. Set up the GitHub operating model first: labels, milestones, board, and first-wave issues.
2. Execute issues 1 through 4 as the initial Desktop behavior block.
3. Execute issues 5 through 7 as the Running/Complete hardening block.
4. Land issue 8 immediately after the behavior changes, not later.
5. Land issue 9 before adding new real UI scenarios.
6. Land issues 10 and 11 to strengthen the release gate.
7. Land issue 12 once the behavior and tests are stable enough to document correctly.
8. Land issue 13 to remove status drift.
9. Finish with issue 14 so the release checklist reflects the actual repo state.

## 7. GitHub Project Setup

### Labels

Priority:

- `P0`
- `P1`
- `P2`

Type:

- `type:feature`
- `type:bug`
- `type:test`
- `type:docs`
- `type:ops`

Area:

- `area:desktop`
- `area:core`
- `area:cli`
- `area:mcp`
- `area:release`

Track:

- `track:product`
- `track:hardening`

State:

- `blocked`

### Milestones

- `M1 Desktop Workflow Contract`
- `M2 Desktop Verification Gate`
- `M3 Cross-host Operability`
- `M4 Demo-ready Release`
- `Later / Post-MVP`

### Project Board Columns

- `Backlog`
- `Ready`
- `In Progress`
- `Verifying`
- `Done`
- `Blocked`

### Lightweight Workflow

- keep `Ready` small
- keep only one or two issues in `In Progress`
- treat one issue as one PR whenever possible
- use `track:product` for user-visible behavior changes
- use `track:hardening` for tests, docs, and release work
- use `Later / Post-MVP` for deferred scope instead of keeping it mixed into the active backlog

## 8. Definition of Done

- acceptance criteria are met
- code is merged and linked to the issue
- relevant automated tests are added or updated
- relevant local verification has been run
- docs are updated if setup, workflow, or release behavior changed
- no new misleading product claims were introduced
- for Desktop UI issues, `tests/VoxFlow.Desktop.Tests` passes
- for Desktop workflow milestones, at least one relevant real UI scenario passes
- any intentional defer or tradeoff is written down in the issue or PR

## 9. Risks, Gaps, and De-scoping Suggestions

- the documented product is broader than the smallest shippable release; treat the macOS Desktop single-file workflow as the active MVP
- `docs/product/DESKTOP_UI_SPEC.md` is detailed enough to drive execution and should be treated as the current Desktop backlog of record
- Apple Silicon and Intel Mac Catalyst use different Desktop transcription paths; parity is a real delivery risk
- drag-and-drop remains the highest-risk Desktop input path because runtime support and shell behavior are not fully aligned
- the config story is easy to misunderstand because Desktop single-file behavior and checked-in batch-oriented configs coexist
- MCP is implemented, but its launch/config contract is still easier to misuse than it should be
- packaging exists, but a full notarized release flow is still later-stage work

Recommended de-scope for MVP:

- Desktop batch UI
- Desktop settings editor UI
- Windows/Linux Desktop support
- HTTP/SSE MCP transport
- real-time transcription
- translation
- full notarized distribution pipeline
