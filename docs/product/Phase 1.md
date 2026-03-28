# VoxFlow Phase 1

## Phase Goal

Ship a stable, demoable macOS Desktop single-file transcription workflow and back it with enough test coverage that ongoing delivery can stay disciplined.

This phase intentionally does not try to finish the entire PRD. It focuses on the most visible execution path in the current repo:

- Desktop launch
- startup validation handling
- single-file intake
- running progress
- failure and cancel recovery
- result review actions

## Why This Is Phase 1

The repository already has:

- a shared Core transcription pipeline
- a working CLI
- batch support in CLI/Core
- MCP tools and path safety
- a Desktop app with real UI automation already covering launch and happy path

The immediate delivery gap is therefore not foundational engineering. It is product-surface closure:

- finish the Desktop UI contract
- make Desktop behavior safe and truthful
- close the remaining test coverage gaps

## Phase 1 Scope

In scope:

- Desktop UI contract fixes from `docs/product/DESKTOP_UI_SPEC.md`
- Desktop state-management hardening
- Desktop fast tests
- Desktop real UI automation
- enough doc alignment to support iterative shipping

Out of scope:

- Desktop batch UI
- Desktop settings editor
- Windows/Linux desktop support
- new MCP features
- CLI feature expansion
- notarized release pipeline

## Phase 1 Success Criteria

- Desktop Ready, Running, Failed, and Complete states behave consistently and truthfully
- no file intake path can bypass blocked startup validation or invalid workflow state
- transcript preview and copy behavior are honest and consistent across Desktop runtime paths
- the fast Desktop suite covers the corrected behavior
- the real UI suite covers more than launch and happy path
- the repo has a clear first-wave GitHub backlog and release gate

## Phase 1 Workstreams

### Workstream A: Desktop UI Contract

Target outcome:

- the Desktop app matches the actual single-file local workflow documented in the PRD and UI spec

Deliverables:

- corrected Ready-screen copy
- guarded file intake
- cleaned-up run transitions
- improved Running progress semantics
- hardened Complete-screen actions

### Workstream B: Desktop Test Gate

Target outcome:

- Desktop regressions are caught early and visibly

Deliverables:

- expanded `tests/VoxFlow.Desktop.Tests`
- expanded `tests/VoxFlow.Desktop.UiTests`
- stable automation ids and tracked state

### Workstream C: Operational Clarity

Target outcome:

- a solo developer can build, test, and demo the active product without reading the whole repo

Deliverables:

- explicit smoke routine
- status docs aligned with the current repo
- manual demo-release checklist

## Phase 1 Issue Set

### A1. Correct Ready-screen copy and capability messaging

Acceptance criteria:

- Ready state describes one local audio file
- no `upload` or `multiple files` claims remain
- drag-and-drop wording is runtime-aware

### A2. Enforce Ready-state start guard in AppViewModel

Acceptance criteria:

- blocked validation cannot start a run
- invalid workflow states cannot start a run
- tests cover the guard

### A3. Make shell-level drag-and-drop obey the Ready-state contract

Acceptance criteria:

- drop cannot bypass blocked Ready
- drop cannot start outside the valid Ready state
- unsupported dropped files fail before `Running`

### A4. Clear transient Desktop state on new run, retry, and cancel

Acceptance criteria:

- new runs start clean
- cancel returns to a clean Ready state
- retries do not leak stale state

### A5. Improve Running-screen progress semantics and labels

Acceptance criteria:

- numeric percent is visible
- labels are human-readable
- progressbar semantics exist
- starting state is visible before first progress event

### A6. Normalize preview and full-transcript copy behavior

Acceptance criteria:

- preview rules are consistent across Desktop runtime paths
- full transcript is copied when available
- preview truncation or preview-unavailable state is explicit

### A7. Surface startup warnings and non-fatal Complete-screen action errors

Acceptance criteria:

- non-blocking startup warnings are visible
- missing result metadata disables or hides invalid actions
- copy/open-folder failures remain non-fatal and visible

### B1. Expand fast Desktop tests for the updated UI contract

Acceptance criteria:

- ViewModel and component tests cover the new guard, cleanup, warning, progress, and result rules

### B2. Extend the Desktop automation bridge tracked ids

Acceptance criteria:

- startup error and validation-message visibility are exposed to the UI suite
- existing scenarios keep passing

### B3. Add real UI scenario for startup failure and blocked-ready

Acceptance criteria:

- one real UI scenario covers startup retry
- one real UI scenario covers Ready Blocked

### B4. Add real UI scenario for cancel and failure recovery

Acceptance criteria:

- cancel returns to Ready without stale state
- failure recovery remains green end-to-end

### C1. Document the local config and smoke workflow for all active hosts

Acceptance criteria:

- Desktop, CLI, and MCP launch contracts are explicit
- one recommended smoke routine exists

### C2. Align status docs with the actual repo state

Acceptance criteria:

- README, setup docs, and architecture notes no longer disagree about current Desktop status

### C3. Create a demo-ready macOS release checklist

Acceptance criteria:

- build, smoke, package, and verification steps are documented
- known release gaps are called out explicitly

## Suggested PR Sequence

1. `A1` Ready-screen copy cleanup
2. `A2` ViewModel start guard
3. `A3` shell-level drag-and-drop guard
4. `A4` transient state cleanup
5. `A5` Running-screen progress improvements
6. `A6` preview and copy normalization
7. `A7` warnings and non-fatal action errors
8. `B1` fast-test expansion
9. `B2` automation bridge update
10. `B3` real UI startup/blocked-ready coverage
11. `B4` real UI cancel/failure coverage
12. `C1` local smoke workflow docs
13. `C2` status-doc alignment
14. `C3` demo-release checklist

## Phase 1 Release Gate

Minimum verification before calling Phase 1 complete:

- `dotnet test tests/VoxFlow.Desktop.Tests/VoxFlow.Desktop.Tests.csproj`
- `./scripts/run-desktop-ui-tests.sh --filter AppStartsSuccessfully_AndReadyScreenIsVisible`
- `./scripts/run-desktop-ui-tests.sh --filter HappyPath_UserSelectsFile_SeesRunningState_AndGetsResult`
- targeted real UI filters for the new blocked-ready and cancel/failure scenarios

## After Phase 1

Only after Phase 1 is complete should the active roadmap move to:

- broader cross-host polish
- packaging and release maturity
- post-MVP scope such as Desktop batch UI or settings UI
