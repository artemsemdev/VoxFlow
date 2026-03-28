# VoxFlow Desktop UI Specification

## 1. Document Metadata

| Field | Value |
|---|---|
| Title | `VoxFlow Desktop UI Specification` |
| Repository | `artemsemdev/VoxFlow` |
| Status | Working Spec |
| Intended Audience | Desktop engineers, QA engineers, UI automation engineers, product/documentation maintainers |
| Last Updated | March 28, 2026 |
| Basis | Current implementation in `src/VoxFlow.Desktop`, desktop tests, product docs, and desktop automation scaffolding |

## 2. Purpose

The VoxFlow Desktop App exists to provide a visual, local-first transcription workflow for macOS users who need to transcribe one local audio file at a time without using the CLI.

The Desktop UI is the product surface that:

- MUST make the single-file transcription workflow understandable without reading source code or configuration files.
- MUST show whether the app is ready to start transcription.
- MUST show truthful runtime progress while transcription is active.
- MUST support recovery from startup issues, picker failures, transcription failures, and user cancellation.
- MUST expose the result in a way that lets the user review, copy, and locate the generated transcript file.

The Desktop UI is not an independent transcription engine. It is a state-driven host over the shared VoxFlow transcription pipeline and, on Intel Mac Catalyst, over the local CLI bridge.

## 3. Scope

This specification covers the current Desktop UI contract for `src/VoxFlow.Desktop`.

In scope:

- app launch and startup initialization
- startup validation outcomes as rendered in the UI
- startup fatal error handling and retry
- the Ready, Running, Failed, and Complete screens
- local file intake through the system picker and drag-and-drop
- cancellation behavior
- result review and result actions
- user-facing terminology, accessibility, and stable automation identifiers
- UI behavior that QA and automation must later verify

Out of scope:

- batch-processing UI
- transcript editing
- settings editor UI
- configuration authoring UI
- model-management UI beyond surfaced validation and run status
- CLI behavior except where the Desktop app delegates to it
- MCP behavior
- Windows or Linux desktop support
- real-time transcription
- speaker diarization, translation, or collaboration features

Desktop UI responsibilities:

- render the current user-visible workflow state
- prevent UI actions when transcription cannot start
- pass the selected file into the transcription pipeline
- map progress data into understandable UI status
- expose failure recovery actions
- expose result review and shell actions

Responsibilities that belong outside the UI:

- transcription logic, filtering, language selection, output writing, and model management belong to `VoxFlow.Core`
- CLI bridge invocation and CLI output parsing belong to Desktop shell/services, not Razor views
- persistent configuration merging belongs to `DesktopConfigurationService`
- the exact transcript file format belongs to Core/CLI, not the UI

## 4. Supported Platform and Constraints

Current supported platform:

- The Desktop app currently targets macOS only through `.NET 9` MAUI Blazor Hybrid on `net9.0-maccatalyst`.
- The declared supported Mac Catalyst platform version is `15.0` or later.
- The app is a native desktop host that renders a Blazor UI inside `BlazorWebView`.

Runtime constraints:

- Apple Silicon uses the shared in-process transcription pipeline.
- Intel Mac Catalyst uses a local `VoxFlow.Cli` bridge for transcription.
- The Desktop app is a single-window application.
- The Desktop app is currently a single-file workflow. Batch mode is intentionally out of Desktop UI scope even though batch exists elsewhere in the repository.
- The UI depends on local filesystem access for input selection, output writing, model storage, clipboard integration, and folder opening.

Intentional exclusions:

- Windows desktop and Linux desktop are not supported in the current Desktop product scope.
- Browser deployment is not supported.
- The UI MUST NOT imply cloud upload, cloud processing, or remote storage.

Important limitation:

- Drag-and-drop behavior is currently architecture-dependent in the implementation. This specification defines the intended user contract and explicitly calls out the current mismatch later.

### Visual Design Expectations

- The Desktop app uses a dark theme consistent with macOS design conventions.
- The color palette, typography, and spacing should feel native to macOS rather than web-first.
- The visual hierarchy must make the current workflow state immediately obvious: ready, busy, failed, or complete.
- Interactive controls must have visible focus indicators for keyboard navigation.
- This specification does not prescribe exact colors, fonts, or pixel values. Visual details are an implementation concern within the design constraints above.

## 5. Target User and Usage Context

The Desktop app targets Mac users who need private, local transcription of recorded audio such as meetings, interviews, calls, and voice notes.

Typical usage context:

- the user has one local audio file they want transcribed now
- the user expects the file to remain on the local machine
- the user expects a straightforward flow: launch, choose one file, wait, review, copy or open the result, then process another file
- the user expects the app to state clearly whether it is blocked by environment/configuration issues before wasting time on a run

The user is likely to expect a local transcription app to:

- avoid “upload” language
- show honest progress rather than a frozen interface
- fail clearly when the environment is not valid
- let them retry without relaunching when the problem is per-file rather than per-app
- avoid hiding where the result file was written

## 6. Product Principles for the Desktop UI

The Desktop UI MUST follow these principles.

### 6.1 Local-First

- The UI MUST describe file intake as local file selection or local drag-and-drop.
- The UI MUST NOT describe the action as “upload” unless the product actually uploads data, which VoxFlow Desktop does not.

### 6.2 Privacy-First

- The UI MUST NOT imply that audio leaves the device.
- The UI MUST NOT imply a cloud fallback or online service dependency for transcription itself.

### 6.3 Honest System Status

- The UI MUST clearly distinguish between:
  - startup fatal error
  - ready and able to run
  - ready but blocked by validation
  - actively running
  - failed run
  - completed run
- The UI MUST NOT present a selectable file action when the run is blocked.

### 6.4 Clear Recoverability

- Each non-success state MUST either provide a valid next action or clearly indicate that recovery requires external changes and relaunch.
- Cancellation MUST be treated as a recoverable user action, not as a failure.

### 6.5 Minimal but Explicit Workflow

- The Desktop UI MUST stay focused on the current single-file workflow.
- The UI MUST NOT imply queueing, batch processing, or multi-file ingestion.

### 6.6 No Misleading Capability Claims

- The UI MUST only claim file formats, drag-and-drop support, and result actions that are actually available.
- If a runtime capability is unavailable, the UI MUST degrade copy and affordances accordingly rather than continue to advertise the missing capability.

### 6.7 Accessible and Testable by Design

- Every primary screen and primary action MUST have a stable identifier and accessible name.
- Important status changes MUST be machine-detectable and screen-reader-detectable.

## 7. Core User Journey

The primary happy path is:

1. The user launches VoxFlow Desktop.
2. The app loads the effective Desktop configuration and runs startup validation.
3. If initialization succeeds and validation allows execution, the app shows the Ready screen.
4. The user selects one local audio file through `Browse Files` or drops one file onto the app when drag-and-drop is available.
5. The app transitions to the Running screen immediately and begins transcription.
6. The app shows the selected file name, active stage, progress, elapsed time, and language information when available.
7. When transcription succeeds, the app transitions to the Complete screen.
8. The user reviews the transcript preview, copies the transcript, opens the result folder, or returns to Ready.
9. The user returns to the Ready screen and may process another file.

Important alternate paths:

- If startup initialization throws, the app shows the Startup Error screen with Retry.
- If startup validation fails in a blocking way, the app stays on the Ready screen, shows the blocking message, and disables file intake.
- If transcription fails after starting, the app shows the Failed screen with Retry and Choose Different File.
- If the user cancels during Running, the app returns to Ready without a Failed state.

## 8. Screen and State Inventory

The Desktop UI has the following user-visible states.

| State / Screen | User-Visible Identifier | Purpose |
|---|---|---|
| Startup Initializing | No stable product screen; transient host bootstrapping only | Load config and run startup validation before the main state machine is usable |
| Startup Error | `startup-error-screen` | Show fatal initialization failure and allow retry |
| Ready Available | `ready-screen` | Accept a single local audio file for transcription |
| Ready Blocked | `ready-screen` plus `startup-validation-message` | Show blocking startup validation failures and disable file intake |
| Running | `running-screen` | Show active transcription status and allow cancellation |
| Failed | `failed-screen` | Show transcription failure and recovery actions |
| Complete | `complete-screen` | Show result summary, transcript preview, and result actions |

No other user-visible screens are currently in scope. The Desktop UI does not define separate Settings, History, Batch, or Transcript Editor screens.

## 9. Formal App State Model

### 9.1 State Layers

The Desktop UI has two layers of state:

- a route-level startup layer handled by `Routes.razor`
- a workflow layer handled by `AppViewModel`

The route-level layer decides whether the user sees:

- startup fatal error, or
- the main workflow layout

The workflow layer decides whether the user sees:

- Ready
- Running
- Failed
- Complete

### 9.2 State Definitions

#### Startup Initializing

Meaning:

- The app has launched but the workflow is not yet initialized.

Entry conditions:

- app launch
- user triggers startup retry from the Startup Error screen

Exit conditions:

- successful configuration load and validation result creation
- fatal exception during initialization

Required data:

- none that is yet user-actionable

#### Startup Error

Meaning:

- a fatal exception occurred during `InitializeAsync()`
- the workflow state machine is not available

Entry conditions:

- configuration loading throws
- startup validation throws unexpectedly
- any other exception escapes initialization

Exit conditions:

- user activates Retry and initialization succeeds

Required data:

- fatal startup message

#### Ready Available

Meaning:

- the app is initialized
- startup validation does not block transcription
- the user may start a new single-file run

Entry conditions:

- initialization succeeds with `ValidationResult.CanStart == true`
- user cancels from Running
- user selects `Choose Different File` from Failed
- user selects back-to-ready from Complete

Exit conditions:

- user starts a valid file intake action

Required data:

- current `ValidationResult`

#### Ready Blocked

Meaning:

- the app initialized successfully but startup validation returned `CanStart == false`
- the user may not start transcription

Entry conditions:

- initialization succeeds with `ValidationResult.CanStart == false`

Exit conditions:

- full app reinitialization with a non-blocking validation result

Required data:

- current `ValidationResult`
- blocking validation message derived from failed checks

#### Running

Meaning:

- a single transcription request is active

Entry conditions:

- the user starts a new valid file run from Ready Available
- the user selects Retry from Failed and the prior file path is still available

Exit conditions:

- transcription succeeds
- transcription fails
- user cancellation completes

Required data:

- selected input file path
- active cancellation token source
- progress data, which MAY be absent briefly until the first update arrives

#### Failed

Meaning:

- a transcription attempt started and ended unsuccessfully

Entry conditions:

- transcription service returns `Success == false`
- transcription pipeline throws an exception other than cancellation

Exit conditions:

- user selects Retry
- user selects Choose Different File

Required data:

- last selected file path for Retry
- failure message

#### Complete

Meaning:

- a transcription attempt finished successfully

Entry conditions:

- transcription service returns `Success == true`

Exit conditions:

- user selects Back To Ready Screen

Required data:

- successful `TranscriptionResult`
- last selected file path

### 9.3 Allowed Transitions

| From | Event | Preconditions | To | Notes |
|---|---|---|---|---|
| Startup Initializing | initialization succeeds | `ValidationResult.CanStart == true` | Ready Available | main workflow becomes usable |
| Startup Initializing | initialization succeeds | `ValidationResult.CanStart == false` | Ready Blocked | blocked-ready is still a successful initialization |
| Startup Initializing | initialization throws | none | Startup Error | fatal startup path |
| Startup Error | Retry succeeds | none | Ready Available or Ready Blocked | depends on validation outcome |
| Startup Error | Retry throws | none | Startup Error | error screen remains |
| Ready Available | valid file selected/dropped | file intake action is accepted | Running | single-file only |
| Ready Blocked | file intake attempted | any | Ready Blocked | intake MUST be rejected |
| Running | transcription succeeds | none | Complete | successful run |
| Running | transcription fails | non-cancellation failure | Failed | unsuccessful run |
| Running | user cancels | cancellation completes | Ready Available | cancellation is recoverable |
| Failed | Retry | last file path exists | Running | reruns same file |
| Failed | Choose Different File | none | Ready Available | clears run data, keeps startup validation state |
| Complete | Back To Ready Screen | none | Ready Available | prepares for another file |

### 9.4 Forbidden Transitions

The following transitions are forbidden by product behavior:

- Startup Error -> Running
- Ready Blocked -> Running
- Complete -> Running without first returning to Ready
- Failed -> Complete without a new run
- Running -> Startup Error

Any shell-level file intake path, including native drag-and-drop, MUST obey the same transition rules as the visible Ready screen controls.

### 9.5 Data Lifetime Rules

Persistent during the app session until reinitialization:

- `ValidationResult`
- effective startup-derived readiness state

Transient per run and MUST be cleared when a new run starts or when the user returns to Ready:

- current file name/path shown to the user
- current progress
- error message
- previous transcription result
- complete-screen copied confirmation state
- file-selection error message

Internal retry data:

- the last file path MAY be retained internally only to support the Retry action from Failed
- once the user leaves Failed, prior run identity MUST NOT remain visible on Ready

## 10. Startup and Initialization Specification

### 10.1 Initialization Responsibilities

At startup, the app MUST:

1. create the Desktop host and Blazor shell
2. load the effective Desktop transcription configuration
3. normalize Desktop file paths for documents, artifacts, temp, and model storage
4. run startup validation against the effective configuration
5. store the validation result for Ready-state rendering
6. select the appropriate Ready variant or the Startup Error screen

### 10.2 Configuration Sources

The Desktop initialization path MUST use the Desktop configuration merge behavior:

1. bundled `src/VoxFlow.Desktop/appsettings.json`
2. user overrides at `~/Library/Application Support/VoxFlow/appsettings.json`
3. explicit override path only when supplied programmatically

The Desktop host MUST normalize Desktop-oriented paths before validation and runtime use.

### 10.3 Intel CLI Bridge Startup Behavior

On Intel Mac Catalyst:

- Desktop startup MAY suppress in-process Whisper-specific validation checks that are not valid for the CLI bridge path.
- This suppression MUST apply only to startup compatibility checks.
- The actual transcription run MUST still use a full merged configuration appropriate for the CLI path.

### 10.4 Startup Validation Failure vs. Fatal Initialization Error

Blocking startup validation failure:

- MUST NOT be treated as a startup crash
- MUST leave the user on the Ready screen
- MUST show a blocking validation message
- MUST disable all transcription-starting actions
- MUST preserve enough information for the user to understand why transcription cannot start

Fatal initialization error:

- MUST suppress the main workflow layout
- MUST show the Startup Error screen instead
- MUST show the failure message
- MUST expose Retry

### 10.5 Retry Availability

Retry at startup is available only for fatal initialization errors.

The startup Retry action MUST:

- clear the previous fatal startup message before reattempting initialization
- rerun the full initialization path, not a partial refresh
- either land on Ready Available / Ready Blocked or return to Startup Error with the new message

The current Desktop scope does not include an in-app “Re-run startup validation” action on the Ready screen. If the app is in Ready Blocked, recovery currently requires external fixes and app reinitialization.

### 10.6 Startup-Related User Visibility

The user MUST see:

- a distinct startup-error surface for fatal initialization errors
- a distinct blocked-ready message for blocking validation failures
- no misleading “ready” affordance when startup validation prevents execution

The transient host placeholder that may appear before Blazor initialization is not part of the supported UX contract and MUST NOT be used as a stable automation target.

## 11. Ready Screen Specification

### 11.1 Purpose

The Ready screen is the single entry point for starting a new transcription run.

### 11.2 Required Visible Elements

The Ready screen MUST contain:

- a stable screen container with id `ready-screen`
- a primary title with id `ready-screen-title`
- instructional copy describing the single-file local workflow
- a primary file intake surface with id `file-drop-zone`
- a primary browse button with id `browse-files-button`
- optional startup validation messaging
- optional file-selection error messaging

### 11.3 Title and Instructional Copy

The Ready screen title SHOULD remain `Audio Transcription`.

Instructional copy MUST:

- describe local audio-file transcription
- describe a single-file workflow
- mention drag-and-drop only when drag-and-drop is actually available at runtime
- avoid “upload” language

Instructional copy MUST NOT:

- claim multiple-file support
- claim batch behavior
- claim `M4A`-only support unless the file intake contract is actually restricted to `M4A`

### 11.4 Idle / Default State

When startup validation allows execution, the Ready screen MUST:

- show an enabled file intake surface
- show no stale file name from a previous run
- show no stale failure message from a previous run
- show no stale progress from a previous run
- show no stale result preview from a previous run

### 11.5 Behavior When Startup Validation Blocks Transcription

When `ValidationResult.CanStart == false`, the Ready screen MUST:

- remain the active screen
- render a blocking message in `startup-validation-message`
- disable `browse-files-button`
- disable keyboard activation of the drop zone
- reject drag-and-drop and any other shell-level start action
- avoid transitioning to Running

The blocking message MUST communicate that transcription will not start until the underlying issue is fixed.

### 11.6 Non-Blocking Startup Warnings

When startup validation succeeds with warnings, the Ready screen SHOULD show a non-blocking warning or status message that keeps file intake enabled.

The warning surface MUST be visually distinct from a blocking failure and MUST NOT disable file intake.

### 11.7 Claims the UI Must and Must Not Make

The Ready screen MUST communicate:

- this is a local transcription workflow
- one file is selected per run

The Ready screen MUST NOT communicate:

- multiple file upload
- batch processing
- cloud upload
- unsupported format restrictions

## 12. File Selection Specification

### 12.1 Input Model

The Desktop UI is a single-file workflow.

Rules:

- The UI MUST accept at most one file per run.
- The UI MUST NOT describe the workflow as multiple-file ingestion.
- If the platform supplies multiple dropped files, the UI MUST reject the action with a clear single-file message rather than silently implying batch behavior.

### 12.2 Allowed File Types

The Desktop UI input contract is “one local audio file.”

For predictable behavior across runtime paths, the app MUST accept at least these extensions when a local path is received:

- `.m4a`
- `.wav`
- `.mp3`
- `.aac`
- `.flac`
- `.ogg`
- `.aif`
- `.aiff`
- `.mp4`
- `.m4b`

The system picker MAY expose a broader platform-native audio filter. UI copy SHOULD therefore say `audio file` or `supported audio file` rather than listing only `M4A` unless the implementation is intentionally narrowed.

### 12.3 Browse Button Behavior

Trigger:

- click on `browse-files-button`
- click on the enabled drop zone container
- keyboard activation of the enabled drop zone

Expected behavior:

- The app MUST open the native system file picker.
- The picker MUST allow selection of one local audio file.
- On a successful selection, the app MUST start transcription for that file.
- On picker cancel, the app MUST remain on Ready and show no error.
- On picker exception, the app MUST remain on Ready and show `file-selection-error`.

### 12.4 Drop-Zone Behavior

The drop zone serves two roles:

- clickable/keyboard-activatable browse entry point
- drag-and-drop target when drag-and-drop is truly available

When drag-and-drop is available:

- dropping one supported local audio file onto the app in Ready Available MUST start transcription for that file
- dropping an unsupported or ambiguous input MUST show a selection error and remain on Ready

When drag-and-drop is not available:

- the UI MUST NOT imply that dropping is supported
- the drop zone MAY remain as a clickable browse affordance only

### 12.5 Keyboard Activation

When the drop zone is enabled:

- `Enter` MUST invoke the same picker action as clicking the drop zone
- `Space` MUST invoke the same picker action as clicking the drop zone

When the drop zone is disabled:

- it MUST NOT be focusable
- keyboard activation MUST do nothing

### 12.6 Invalid File Behavior

If the UI receives a path that does not satisfy the supported input contract:

- the app MUST NOT enter Running
- the app MUST show a user-visible selection error
- the app MUST remain on Ready

If the file is a supported audio type but the underlying audio content is corrupt or unreadable:

- the app MAY enter Running because the failure occurs during processing
- the app MUST then transition to Failed with an error message

### 12.7 Picker Cancel Behavior

Picker cancel is not an error.

On cancel:

- no error banner MUST appear
- no run MUST start
- the current screen MUST remain Ready
- any existing non-related blocking validation banner MAY remain

### 12.8 Successful Selection Behavior

After successful selection of one valid file:

- any prior file-selection error MUST clear
- stale run data MUST clear
- the selected file name MUST become the current file identity
- the app MUST transition immediately to Running

### 12.9 Action Gating

File intake actions MUST be accepted only when:

- the active screen is Ready Available
- no run is already in progress
- startup validation is not blocking

File intake actions MUST be ignored or rejected in:

- Startup Error
- Ready Blocked
- Running
- Failed
- Complete

## 13. Running Screen Specification

### 13.1 Purpose

The Running screen exists to prove that work is in progress, show the current stage honestly, and provide cancellation.

### 13.2 Required Visible Elements

The Running screen MUST contain:

- a stable screen container with id `running-screen`
- the selected file name in `running-file-name`
- a progress indicator
- stage/status text in `running-stage`
- elapsed time when available
- the cancel action `cancel-transcription-button`

### 13.3 File Name Behavior

- The screen MUST show the base file name, not the full path.
- The file name MUST reflect the currently running file, not the previous run.
- Generic fallback text such as `audio file` SHOULD be used only when the current file name is unexpectedly unavailable.

### 13.4 Progress Indicator Behavior

When a determinate `PercentComplete` value is available:

- the screen MUST render a determinate progress indicator
- the value MUST be clamped to `0-100`
- the visible percentage SHOULD be shown as a whole number
- the progress indicator MUST expose accessible progressbar semantics

When progress data is not yet available:

- the screen MUST show an indeterminate busy indicator
- the screen MUST still provide textual feedback that transcription has started

### 13.5 Stage and Message Display Rules

- Stage labels MUST be human-readable, not raw enum tokens.
- The stage label MUST reflect the current `ProgressStage` when progress exists.
- The stage message MAY append more detail from `ProgressUpdate.Message`.
- If no message exists yet, the screen SHOULD still show a generic startup status such as `Starting transcription...`.

Expected human-readable stage labels:

| ProgressStage | User-Facing Label |
|---|---|
| `Validating` | `Validating` |
| `Converting` | `Converting` |
| `LoadingModel` | `Loading model` |
| `Transcribing` | `Transcribing` |
| `Filtering` | `Filtering` |
| `Writing` | `Writing` |
| `Complete` | `Complete` |
| `Failed` | `Failed` |

### 13.6 Percent Display Rules

- The user-visible percent SHOULD represent the same value used by the visual progress indicator.
- The UI MUST NOT show a fabricated percentage when the actual value is unavailable.
- If the progress is indeterminate, the screen MUST rely on stage text and a busy indicator instead of a fake `0%`.

### 13.7 Elapsed Time Rules

- Elapsed time MUST be based on the active run only.
- Elapsed time MUST be non-decreasing during the run.
- The formatting MUST be `m:ss` for durations under one hour and `h:mm:ss` for durations of one hour or more.
- Elapsed time MUST reset for each new run.

### 13.8 Language Display Rules

- The Running screen MAY show the current language only when the pipeline has produced language information.
- The screen MUST NOT show a language label before a value exists.
- The running-language label MUST be treated as dynamic status, not as final metadata.

### 13.9 Behavior When Progress Data Is Temporarily Unavailable

The app MUST support a short interval between run start and first `ProgressUpdate`.

During that interval:

- the user MUST still see that the app is busy
- the file name MUST still be visible
- cancellation MUST remain available
- stale progress from a previous run MUST NOT be displayed

### 13.10 Cancel Behavior

The Cancel action MUST:

- request cancellation of the active run
- be available only while Running
- return the app to Ready when cancellation completes
- avoid showing a failure screen for user-requested cancellation
- clear transient run data before the next run begins

### 13.11 Completion and Failure Behavior

After Running:

- success MUST transition to Complete
- non-cancellation failure MUST transition to Failed
- cancellation MUST transition to Ready

## 14. Failed Screen Specification

### 14.1 Definition of Failed Transcription State

A run is in the Failed state when:

- a transcription attempt began, and
- the transcription service returned `Success == false`, or
- the transcription pipeline threw an exception other than cancellation

Cancellation is not a failed state.

### 14.2 Required Visible Elements

The Failed screen MUST contain:

- a stable screen container with id `failed-screen`
- a failure title
- the primary failure message in `transcription-error-message` when available
- `retry-transcription-button`
- `choose-different-file-button`

### 14.3 Failure Message Rules

- The failure message MUST describe why the run failed as directly as possible.
- If multiple failure details exist, they MAY be joined into a single user-visible message.
- The message MUST be text, not color-only indication.

### 14.4 Retry Behavior

Retry MUST:

- rerun the last selected file
- clear stale progress, stale result, and stale error state before the new run starts
- transition directly to Running

Retry SHOULD be disabled when no previous file path exists, though that condition is not reachable through the normal current UI flow.

### 14.5 Choose Different File Behavior

Choose Different File MUST:

- return to Ready
- preserve startup validation state
- clear prior run failure text
- clear prior result data
- clear prior progress data

The user MUST be able to recover without restarting the app for per-file failures.

### 14.6 Data Preservation and Clearing

Preserved across Failed -> Retry:

- last selected file path
- current startup validation result

Cleared when a new run starts or when the user leaves Failed:

- current failure message
- previous progress
- previous result
- any copied confirmation state

## 15. Complete Screen Specification

### 15.1 Purpose

The Complete screen is a result summary surface, not a full transcript editor.

### 15.2 Required Visible Elements

The Complete screen MUST contain:

- a stable screen container with id `complete-screen`
- back-to-ready action `back-to-ready-button`
- current file name in `result-file-name`
- detected language when available in `result-language`
- transcript preview region `transcript-preview` when preview text is available
- `open-folder-button`
- `copy-text-button`

### 15.3 Result Header

- The result header MUST identify the completed file.
- The back action MUST return the user to Ready.
- The header MUST NOT expose a stale file name from a previous run.

### 15.4 File Name Display

- The file name MUST be the base name of the input file that produced the result.
- The full input path SHOULD NOT be shown in the default UI.

### 15.5 Detected Language Display

- The Complete screen SHOULD show detected language when the transcription result contains it.
- If the detected language is unavailable, the language row MAY be omitted.

### 15.6 Transcript Preview Behavior

The Complete screen MUST show transcript text as a preview, not as an editable document.

Preview rules:

- the preview MUST preserve transcript text order
- the preview MUST be scrollable within the page
- the preview SHOULD be derived consistently across runtime paths
- if the preview is truncated, the UI MUST indicate that it is a preview rather than the full transcript

Intended normalized contract:

- the UI SHOULD receive up to the first `4,000` characters of the transcript for preview
- the UI SHOULD know whether the preview was truncated

### 15.7 Preview Truncation and Scrolling

- Vertical scrolling inside the preview region MUST be supported.
- The UI MUST NOT silently present a truncated preview as though it is the full transcript.
- When truncation is known, the UI SHOULD disclose it.

### 15.8 Open Folder Behavior

Open Folder MUST:

- open the directory containing the generated result file
- not attempt to open a null or invalid directory
- remain a non-destructive shell action

If the result folder path is unavailable:

- `open-folder-button` MUST be disabled or hidden
- the UI SHOULD communicate that the result location is unavailable

### 15.9 Copy Transcript Behavior

`Copy Transcript` is expected to mean the transcript, not merely the current visible preview.

The intended behavior is:

- if the final transcript file is available, the app MUST copy the full transcript text to the clipboard
- if only preview text is available, the app MUST either:
  - label the action as copying preview text, or
  - disable the action rather than silently copying incomplete text under the `Copy Transcript` label

### 15.10 Copied Confirmation Behavior

After successful copy:

- the UI MUST show a visible confirmation state
- the current implementation pattern of a temporary `Copied!` label for about two seconds is acceptable
- the button label MUST then return to its default text

After copy failure:

- the UI MUST show a non-fatal error message
- the button MUST return to a retryable state

### 15.11 Back-To-Ready Behavior

Back To Ready Screen MUST:

- return the app to Ready
- clear current result UI state
- preserve startup validation state
- allow the user to start a new file

### 15.12 Incomplete or Partial Result Metadata

If result metadata is incomplete:

- missing detected language MUST NOT block completion
- missing preview text MUST show a preview-unavailable message rather than a blank omission
- missing result path MUST disable Open Folder
- copy behavior MUST follow the full-transcript rule above and MUST NOT silently degrade

## 16. Detailed Interaction Rules

| Interaction | Trigger | Preconditions | Success Result | Failure Result | Resulting State | User-Visible Feedback |
|---|---|---|---|---|---|---|
| Browse Files | click `browse-files-button` | Ready Available | native picker opens, one valid file selected, app starts run | picker error or invalid selection | Running on success; Ready on failure | file picker appears; on failure show `file-selection-error` |
| Click Drop Zone | click `file-drop-zone` | drop zone enabled and Ready Available | same as Browse Files | same as Browse Files | Running on success; Ready on failure | same as Browse Files |
| Keyboard Activate Drop Zone | `Enter` or `Space` on `file-drop-zone` | drop zone enabled and focused | same as Browse Files | same as Browse Files | Running on success; Ready on failure | same as Browse Files |
| Cancel Transcription | click `cancel-transcription-button` | Running | cancellation requested and honored | cancellation request ignored or cancellation throws unexpected non-cancel exception | Ready on success; Failed only on true non-cancel failure | cancel action acknowledged; no failure banner on normal cancel |
| Retry Startup | click `startup-retry-button` | Startup Error visible | initialization reruns and succeeds | initialization throws again | Ready Available / Ready Blocked on success; Startup Error on failure | startup error clears before retry; new outcome visible |
| Retry Transcription | click `retry-transcription-button` | Failed and previous file exists | same file starts again | rerun fails again | Running, then Complete or Failed | error clears; running state appears |
| Choose Different File | click `choose-different-file-button` | Failed | app returns to Ready | none | Ready | failure UI clears |
| Go Back To Ready | click `back-to-ready-button` | Complete | result state clears | none | Ready | result UI disappears and Ready screen appears |
| Copy Transcript | click `copy-text-button` | Complete and transcript text is available for copy | transcript text copied to clipboard | clipboard API fails or transcript unavailable | Complete | visible copy confirmation on success; visible non-fatal error on failure |
| Open Result Folder | click `open-folder-button` | Complete and result folder path available | Finder opens containing folder | shell open fails or path unavailable | Complete | folder opens on success; visible non-fatal error on failure |

## 17. UX Copy and Terminology Rules

### 17.1 Tone

User-facing copy MUST be:

- concise
- literal
- operational
- local-first

User-facing copy SHOULD avoid:

- marketing language
- unexplained internal terms
- mobile-centric phrasing

### 17.2 Terms That MUST Be Used Consistently

| Preferred Term | Use |
|---|---|
| `Audio file` | generic input file label |
| `Browse Files` | primary file-picker action |
| `Startup validation` | environment/config readiness checks |
| `Transcription` | the active processing run |
| `Transcript` | the text output |
| `Open Folder` | open the containing folder of the result |
| `Choose Different File` | abandon the failed file and return to Ready |

### 17.3 Terms the UI MUST Avoid

| Problematic Term | Why It Is Wrong Here |
|---|---|
| `Upload` | suggests network transfer; Desktop is local-first |
| `Multiple files` | current Desktop scope is single-file |
| `M4A only` | current input handling is broader than only `M4A` |
| raw enum tokens such as `LoadingModel` | not user-friendly |

### 17.4 Current Wording That Is Misleading

The following current wording is misleading and MUST be corrected in later implementation work:

- `Drop your M4A files here to convert speech into text`
- `Supported format: M4A. You can upload multiple files.`
- drag-and-drop wording when drag-and-drop is not actually available on the current runtime

### 17.5 Copy Rules

Ready-state copy MUST communicate:

- single-file local audio selection
- truthful availability of drag-and-drop

Running-state copy MUST communicate:

- current stage truthfully
- no fabricated certainty

Complete-state copy MUST communicate:

- transcript preview versus full transcript accurately

## 18. Accessibility Requirements

### 18.1 Keyboard Accessibility

- All primary actions MUST be reachable by keyboard.
- `browse-files-button`, `cancel-transcription-button`, `retry-transcription-button`, `choose-different-file-button`, `back-to-ready-button`, `copy-text-button`, and `open-folder-button` MUST be keyboard-operable.
- The drop zone MUST be keyboard-operable when enabled and unfocusable when disabled.

### 18.2 Focus Expectations

- Focus SHOULD move to the primary heading or primary actionable control when the active screen changes.
- After Startup Error appears, focus SHOULD move to `startup-retry-button` or the error heading.
- After Failed appears, focus SHOULD move to the failure heading or Retry button.
- After Complete appears, focus SHOULD move to the result header or back button.
- After returning to Ready, focus SHOULD move to `browse-files-button` or `file-drop-zone`.

### 18.3 Screen-Reader Labeling

- Each screen container MUST have a stable accessible name.
- Icon-only controls MUST have explicit accessible names.
- Error and warning banners SHOULD expose alert semantics.
- The transcript preview SHOULD have an accessible label such as `Transcript Preview`.

### 18.4 Progress Accessibility

The Running screen progress indicator MUST expose:

- `role="progressbar"`
- `aria-valuemin="0"`
- `aria-valuemax="100"`
- `aria-valuenow` when determinate
- `aria-valuetext` describing the current stage and percent

The running stage/status text MUST be announced through a polite live region.

### 18.5 Disabled-State Communication

- Disabled actions MUST be programmatically disabled where the platform supports it.
- Custom disabled surfaces MUST also expose `aria-disabled="true"`.
- Disabled controls MUST NOT remain keyboard-focusable unless there is a specific accessible rationale.

### 18.6 Identifier Expectations

Stable ids and accessible names are part of the accessibility and automation contract. Future UI work MUST preserve them or provide an explicit migration plan for QA automation.

## 19. Error Handling Requirements

| Condition | Required UI Behavior | Required State Outcome | Current Coverage Status |
|---|---|---|---|
| Fatal startup exception | show Startup Error with message and Retry | Startup Error | partially implemented |
| Blocking startup validation failure | stay on Ready, show blocking message, disable all run-start actions | Ready Blocked | partially implemented; native drop bypass gap exists |
| Non-blocking startup warnings | show a non-blocking warning/status message | Ready Available | not currently surfaced |
| File picker failure | stay on Ready and show `file-selection-error` | Ready | implemented |
| Picker cancel | stay on Ready with no error | Ready | implemented |
| Unsupported file intake | stay on Ready and show selection error | Ready | not fully implemented |
| Corrupt/invalid audio content | show run failure after processing starts | Failed | covered by tests |
| Transcription pipeline failure | show Failed with message and recovery actions | Failed | implemented |
| Cancellation | return to Ready without failure banner | Ready | implemented at high level; transient-data clearing gap exists |
| Missing transcript preview | keep Complete visible and show preview-unavailable messaging | Complete | not currently implemented |
| Missing result path | keep Complete visible but disable Open Folder | Complete | not currently implemented |
| Clipboard failure | keep Complete visible and show non-fatal copy error | Complete | not currently implemented |
| Folder-opening failure | keep Complete visible and show non-fatal shell-action error | Complete | not currently implemented |

## 20. Edge Cases and Recovery Scenarios

| Scenario | Required Behavior |
|---|---|
| Startup validation blocks transcription | Ready remains visible, blocking message is shown, and no file intake path may start a run |
| Startup initialization throws | Startup Error appears and Retry reruns full initialization |
| User opens picker and cancels | Ready remains unchanged and no error is shown |
| Invalid file is selected | Ready remains active and selection error is shown; no run starts |
| Corrupt audio is selected | Running may begin, then Failed appears with recoverable error |
| Transcription is canceled mid-run | app returns to Ready without showing Failed |
| Progress exists but is incomplete | show whatever progress data is available without inventing absent fields |
| Progress does not yet exist | show indeterminate busy state and textual “starting” feedback |
| Run fails and user retries | same file reruns and stale progress/result/error do not appear |
| Run fails and user chooses another file | app returns to Ready and prior failure state clears |
| Complete screen has no preview text | Complete remains visible and shows explicit preview-unavailable messaging |
| Complete screen has no result folder path | Open Folder is disabled or hidden |
| Stale previous run data appears later | prohibited; new run and Ready return MUST clear transient state |
| Repeated sequential usage | user can complete one file, return to Ready, and run another file without restart |
| Rapid repeated clicks on start actions | only one run may begin; duplicate start actions MUST be ignored or prevented |
| UI copy claims multiple files | prohibited; Desktop scope is single-file |
| UI copy claims drag-and-drop when runtime cannot support it | prohibited; wording MUST be runtime-aware |

## 21. Stable Testability and Automation Contract

### 21.1 Stable Screen Identifiers

The following screen ids are part of the intended automation contract:

| Screen | Stable Id |
|---|---|
| Startup Error | `startup-error-screen` |
| Ready | `ready-screen` |
| Running | `running-screen` |
| Failed | `failed-screen` |
| Complete | `complete-screen` |

### 21.2 Stable Action Identifiers

| Action | Stable Id |
|---|---|
| Retry Startup | `startup-retry-button` |
| File Intake Surface | `file-drop-zone` |
| Browse Files | `browse-files-button` |
| Cancel Transcription | `cancel-transcription-button` |
| Retry Transcription | `retry-transcription-button` |
| Choose Different File | `choose-different-file-button` |
| Back To Ready Screen | `back-to-ready-button` |
| Open Result Folder | `open-folder-button` |
| Copy Transcript | `copy-text-button` |

### 21.3 Stable Status / Content Identifiers

| Purpose | Stable Id |
|---|---|
| Ready title | `ready-screen-title` |
| Startup validation message | `startup-validation-message` |
| File selection error | `file-selection-error` |
| Running file name | `running-file-name` |
| Running stage text | `running-stage` |
| Transcription error message | `transcription-error-message` |
| Result file name | `result-file-name` |
| Result language | `result-language` |
| Transcript preview | `transcript-preview` |

### 21.4 Selector Naming Rules

Future UI changes MUST follow these selector rules:

- ids MUST be stable, semantic, and kebab-case
- ids MUST describe screen role or action role, not visual style
- the same id MUST keep the same semantic purpose across redesigns
- new primary states or actions MUST add stable ids before automation is written

### 21.5 Automation-Relevant Behaviors That SHOULD Be Covered

Future UI automation SHOULD cover at least:

- clean launch to Ready
- fatal startup error and startup retry
- Ready Blocked behavior with disabled intake
- successful file browse flow
- successful drag-and-drop flow when supported
- rejection of unsupported or multi-file input
- Running state visibility and cancel
- failure state and both recovery actions
- completion state, including back-to-ready
- Copy Transcript success and failure handling
- Open Folder success and failure handling
- repeated sequential use without stale state leakage

### 21.6 Active Screen Contract

Any DOM snapshot or automation bridge that reports an active screen SHOULD be able to report exactly one of:

- `startup-error-screen`
- `ready-screen`
- `running-screen`
- `failed-screen`
- `complete-screen`

The automation bridge SHOULD also report visibility of critical message ids, not only action buttons.

## 22. Known Gaps in Current Implementation

The following gaps existed in the repository implementation. Gaps marked **[CLOSED]** were resolved during Phase 1 stabilization (March 2026).

1. **[CLOSED]** The Ready screen and drop zone copy currently claim `M4A` and `multiple files`, but the Desktop workflow is single-file and the runtime accepts broader audio types. *Fixed: copy now describes single local audio file with multi-format support.*
2. **[CLOSED]** The UI currently uses `upload` language in the Ready footer even though the Desktop app is local-only. *Fixed: no “upload” or “multiple files” language remains.*
3. **[CLOSED]** Drag-and-drop is advertised in the Ready UI, but Intel Mac Catalyst explicitly skips native drag-and-drop registration and the JavaScript drop-zone helper is not wired into the actual Razor component. *Fixed: drop zone copy is runtime-neutral (“Choose an audio file to transcribe”).*
4. **[CLOSED]** Blocking startup validation currently disables the visible drop zone controls, but native app-level drag-and-drop can still call `TranscribeFileAsync()` because the shell layer does not enforce the blocked-ready precondition. *Fixed: native drop handler checks `CanStart` before proceeding.*
5. **[CLOSED]** File intake is not fully gated to Ready Available. The native drag-and-drop handler is attached at the shell level and can start a run outside the visible Ready state. *Fixed: `TranscribeFileAsync` enforces `CanStart` guard; native drop also checks `CanStart`.*
6. **[CLOSED]** `AppViewModel.TranscribeFileAsync()` does not clear stale progress or stale prior result state at run start. Retry flows can therefore inherit stale transient data until new progress arrives. *Fixed: `TranscriptionResult`, `CurrentProgress`, and `ErrorMessage` are cleared at run start.*
7. **[CLOSED]** Cancellation returns to Ready, but `CurrentProgress` is not explicitly cleared in the cancellation path. *Fixed: cancellation now calls `GoToReady()` which clears all transient state.*
8. **[CLOSED]** The Running screen currently renders progress visually but does not show a user-visible numeric percent and does not expose proper `progressbar` accessibility semantics. *Fixed: numeric percent is visible as text; progress track has `role=”progressbar”` and `aria-valuenow`.*
9. **[CLOSED]** Running stage text currently uses raw enum `ToString()` output, which will render strings such as `LoadingModel` instead of a human-friendly label. *Fixed: `FormatStage()` renders human-readable labels (e.g., “Loading model”).*
10. **[CLOSED]** Before the first `ProgressUpdate`, the Running screen shows only a spinner and no textual “starting” status. *Fixed: “Starting transcription...” is shown before the first progress event.*
11. **[CLOSED]** Startup validation warnings are not surfaced on the Ready screen when `CanStart == true` but `HasWarnings == true`. *Fixed: non-blocking warnings are shown in a `startup-warning-message` element.*
12. Result preview behavior is inconsistent across runtime paths. The in-process path builds preview text from accepted segments, while the Intel CLI bridge reads back up to `4,000` characters from the result file. *Remains open: preview normalization across runtime paths is a future improvement.*
13. **[CLOSED]** The UI does not currently surface whether the preview is truncated. *Fixed: a “Preview shows a portion of the full transcript” notice appears when preview is shorter than full transcript.*
14. **[CLOSED]** `Copy Transcript` currently copies `TranscriptPreview`, not the full transcript file contents, so the action label over-promises on long transcripts. *Fixed: `GetFullTranscript()` reads the full file; copy sends the full text.*
15. **[CLOSED]** The Complete screen always shows `Open Folder` and `Copy Text` buttons even when the underlying data may be missing, and it does not surface action failures. *Fixed: buttons are hidden when data is missing; action errors are shown non-fatally.*
16. **[CLOSED]** Clipboard failure handling is not surfaced to the user. *Fixed: clipboard errors are caught and shown in `action-error-message`.*
17. **[CLOSED]** Folder-opening failure handling is not surfaced to the user. *Fixed: folder-open errors are caught and shown in `action-error-message`.*
18. Unsupported-path validation is not performed consistently before run start; some invalid intake may fail late instead of as a Ready-state selection error. *Remains open: the start guard prevents invalid states but file-type validation at the Razor layer is not yet added.*
19. Accessibility focus management across screen transitions is currently unspecified and not implemented in the views. *Remains open: deferred to future accessibility work.*
20. **[CLOSED]** The automation bridge currently tracks only a subset of critical elements and does not include startup error or validation-message visibility in its tracked-id list. *Fixed: 27 element IDs are now tracked, including startup-error-screen, startup-validation-message, running-stage, running-percent, transcript-preview, action-error-message, and others.*
21. Real UI automation currently covers browse-based happy path, copy, failure recovery, and repeated use, but does not yet cover fatal startup error, Ready Blocked, drag-and-drop, cancellation, or missing-result metadata states. *Partially addressed: automation bridge now supports these scenarios; B3/B4 real UI test scenarios are defined but require manual execution with the built app.*

## 23. Acceptance Criteria

The Desktop UI is acceptable only when all of the following are true.

1. On launch with valid Desktop configuration, the app reaches `ready-screen` and enables file intake.
2. On launch with a fatal initialization exception, the app shows `startup-error-screen` and `startup-retry-button`, and Retry reruns initialization.
3. On launch with blocking startup validation failure, the app stays on `ready-screen`, shows `startup-validation-message`, and no file intake path can start transcription.
4. The Ready screen describes a single local audio-file workflow and does not claim multiple files or upload.
5. `Browse Files` opens the native picker, picker cancel leaves the app on Ready with no error, and picker failure shows `file-selection-error`.
6. Only one file can start a run. Unsupported or multi-file input is rejected without entering Running.
7. Starting a valid file run transitions immediately to `running-screen` and shows the selected base file name.
8. Running shows truthful stage status, a busy indicator immediately, elapsed time when available, and cancel availability.
9. Determinate progress exposes both visual progress and accessible progressbar semantics.
10. Cancel returns the app to Ready without showing Failed and without leaving stale run data visible.
11. Any non-cancellation run failure transitions to `failed-screen` with an error message, Retry, and Choose Different File.
12. Retry reruns the same file. Choose Different File returns to Ready and clears the failed-run UI.
13. A successful run transitions to `complete-screen` and shows the completed file name, detected language when available, and a transcript preview or explicit preview-unavailable message.
14. `Open Folder` opens the containing folder only when a valid result path exists; otherwise it is disabled or hidden.
15. `Copy Transcript` copies the full transcript when available, shows a visible success confirmation, and handles clipboard failure without leaving the screen.
16. Back To Ready clears result UI state and allows a second file to be processed without restart and without stale state leakage.
17. Stable ids listed in this specification remain available for QA and automation.
18. Drag-and-drop behavior is either implemented truthfully for the current runtime or omitted from user-facing copy on runtimes where it is not available.

## 24. Future Implementation and Testing Guidance

Phase 1 addressed the majority of known gaps. Remaining future work:

- Normalizing preview generation across Apple Silicon (in-process) and Intel (CLI bridge) runtime paths (gap 12)
- Unsupported-file-type validation at the Razor layer before run start (gap 18)
- Accessibility focus management across screen transitions (gap 19)
- Real UI automation scenarios for startup failure, blocked ready, cancel, and failure recovery (gap 21 — bridge support is in place, scenarios need manual or CI execution)
- Drag-and-drop real UI automation (native drop is only available on Apple Silicon)

## 25. Related Documents

| Document | Relationship |
|---|---|
| [PRD.md](PRD.md) | Product requirements that this UI spec implements (see FR-11: Desktop Application, FR-12: Desktop Platform Compatibility) |
| [ROADMAP.md](ROADMAP.md) | Delivery plan; Priority 1 directly addresses the known gaps in this spec |
| [Phase 1.md](Phase%201.md) | Phase 1 workstream and issue breakdown derived from this spec's known gaps and acceptance criteria |
| [ARCHITECTURE.md](../../ARCHITECTURE.md) | System architecture, Desktop host responsibilities, and CLI bridge design |
| [SETUP.md](../../SETUP.md) | Build, test, and packaging instructions for the Desktop app |
