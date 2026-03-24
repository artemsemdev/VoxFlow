# UI Simplification Design

Simplify the VoxFlow Desktop UI: remove configuration/validation screens, settings panel, and status bar. The app starts directly in Ready state with a clean drop zone interface.

## Context

Current UI has 5 states (NotReady, Ready, Running, Complete, Failed) with a settings panel, status bar, and validation checklist. The user wants a simpler 3+1 state flow where configuration is assumed ready by default.

## Design Decisions

- **Remove NotReady state from UI flow.** App always starts in Ready. Validation errors surface at transcription time via the Failed state.
- **Remove SettingsPanel, StatusBar, and settings toggle.** No gear icon, no footer indicators.
- **Keep FailedView** for runtime errors (ffmpeg missing, model not found, transcription errors).
- **Single file processing only.** No batch/queue UI.

## State Machine (new)

```
Ready → Running → Complete
                → Failed → (Retry → Running | Back → Ready)
```

Startup error (config unreadable) still shows a simple error screen with Retry button via Routes.razor — this is unchanged.

## Screen Designs

### 1. Ready (Main Screen)

Layout matches the approved mockup:
- Title: "Audio Transcription"
- Subtitle: "Drop your M4A files here to convert speech into text"
- Drop zone with cloud upload icon, "No files added yet" text, browse link
- "+ Browse Files" button inside drop zone
- Footer hint: supported format info

**MainLayout changes:**
- Remove `<header>` with app title and settings toggle
- Remove `<StatusBar />`
- Remove `@if (_settingsOpen)` block and `_settingsOpen` field
- Content area becomes the only child of `.app-shell`

**ReadyView changes:**
- Replace "Ready to Transcribe" heading with "Audio Transcription"
- Add subtitle matching mockup
- Update DropZone to match mockup styling (cloud icon, "No files added yet" text)
- Add supported format hint below drop zone

### 2. Running (Processing)

Layout matches the approved mockup:
- File card with play icon, filename, and ellipsis menu placeholder
- Progress bar (existing component, reused)
- "Step N of 3: Stage..." label
- Elapsed time display
- Cancel button (secondary style, not danger)

**RunningView changes:**
- Replace "Transcribing..." heading with file card design
- Wrap progress in a bordered card container
- Show filename from ViewModel (requires adding `CurrentFileName` property to AppViewModel)
- Format stage as "Step N of 3: StageName..."
- Move Cancel button outside card, use secondary style

### 3. Complete (Result)

Layout matches the approved mockup:
- Header: back arrow (‹) + filename + ellipsis placeholder
- Language label below header
- Transcript preview in a scrollable container (existing component, reused)
- Two action buttons at bottom: Open Folder + Copy Text

**CompleteView changes:**
- Replace "Transcription Complete" heading with back arrow + filename header
- Add language display (from `DetectedLanguage`)
- Remove success message banner and validation checklist (segments info)
- Remove warnings display
- Keep transcript preview (existing `.transcript-preview` class)
- Replace button labels: "Copy Transcript" → "Copy Text"
- Remove the DropZone at the bottom (use back arrow to start new transcription)
- Back arrow calls new `GoToReady()` method on ViewModel

### 4. Failed (Error)

Minimal changes:
- Keep current layout: error message + Retry + "Choose Different File" buttons
- "Choose Different File" now calls `ViewModel.GoToReady()` instead of `RevalidateAsync()`

## ViewModel Changes

### AppViewModel

- Default state changes: `_currentState = AppState.Ready` (was `NotReady`)
- **New property:** `CurrentFileName` — extracted from `_lastFilePath` via `Path.GetFileName()`
- **New method:** `GoToReady()` — sets `CurrentState = Ready`, clears `ErrorMessage`, `TranscriptionResult`, `CurrentProgress`
- **Modify `InitializeAsync()`:** Always set state to `Ready` (remove `NotReady` branch). Keep validation for future use but don't block UI.
- **Remove:** `IsDownloadingModel` property, `DownloadModelAsync()` method, `RevalidateAsync()` method (no longer needed in UI)

### SettingsViewModel

- **Remove entirely** — no settings panel in the new UI. Remove DI registration from MauiProgram.cs.

### AppState enum

- **Remove `NotReady`** from the enum. Values: `Ready, Running, Failed, Complete`

## Components to Delete

1. `Components/Pages/NotReadyView.razor`
2. `Components/Shared/SettingsPanel.razor`
3. `Components/Shared/StatusBar.razor`
4. `ViewModels/SettingsViewModel.cs`

## Components to Modify

1. `Components/Layout/MainLayout.razor` — remove header, status bar, settings panel
2. `Components/Pages/ReadyView.razor` — new mockup layout
3. `Components/Pages/RunningView.razor` — file card with progress
4. `Components/Pages/CompleteView.razor` — back arrow, filename, transcript, buttons
5. `Components/Pages/FailedView.razor` — use GoToReady()
6. `Components/Shared/DropZone.razor` — update icon and text to match mockup
7. `Components/Routes.razor` — remove NotReady handling, keep startup error
8. `ViewModels/AppViewModel.cs` — simplify state machine
9. `wwwroot/css/app.css` — remove settings/status-bar/validation CSS, add new card styles

## CSS Changes

**Remove:** `.settings-toggle`, `.settings-overlay`, `.settings-panel`, `.settings-*` classes, `.status-bar`, `.status-indicator`, `.status-dot`, `.validation-checklist`, `.validation-item`, `.validation-icon`, `.validation-label`, `.validation-detail`

**Add:**
- `.file-card` — bordered card for running state with file info
- `.result-header` — back arrow + filename header for complete state
- `.upload-icon` — cloud upload icon container in drop zone

**Modify:**
- `.drop-zone` — update to match mockup (cloud icon, new text layout)
- `.app-shell` — remove header spacing, full-height content

## Test Changes

### Tests to Remove

| Test | Reason |
|------|--------|
| `MainLayout_SettingsToggle_OpensSettingsPanel` | Settings panel removed |
| `NotReadyView_RendersRecoveryActions_ForFailedChecks` | NotReadyView deleted |
| `StatusBar_WithoutValidation_ShowsInitializingState` | StatusBar deleted |
| `SettingsPanel_LoadsConfiguredValues_AndSaveClosesPanel` | SettingsPanel deleted |

### Tests to Modify

| Test | Changes |
|------|---------|
| `Routes_WhenInitializationFails_ShowsStartupError_AndRetryRecovers` | Recovery now goes to "Audio Transcription" not "Ready to Transcribe" |
| `RunningView_WithProgress_ShowsDetailedProgress` | Assert against new card layout, check filename display |
| `CompleteView_CopyTranscript_UsesClipboardInterop_AndUpdatesButton` | Button text changes from "Copy Transcript" to "Copy Text", "Copied!" stays |
| `FailedMainLayout_ChooseDifferentFile_Revalidates_ToReady` | Assert "Audio Transcription" not "Ready to Transcribe" |
| `FailedMainLayout_Retry_UsesLastFile_AndTransitions_ToComplete` | Assert new complete view text, not "Transcription Complete" |
| `Routes_BrowseFile_WithRealAudio_CompletesTranscription` | Assert new complete view text |
| `ReadyView_BrowseFile_WithRealAudio_CompletesTranscription` | Same |
| `DropZone_BrowseButton_InvokesCallback_WithSelectedFile` | Browse button text unchanged, test should pass |
| `DropZone_WhenPickerThrows_ShowsSelectionError` | Same |

### Tests to Add

| Test | Purpose |
|------|---------|
| `CompleteView_BackButton_NavigatesToReady` | Back arrow returns to ready state |
| `ReadyView_ShowsExpectedLayout` | Verify title, subtitle, drop zone text |

### Test Infrastructure Changes

- Remove `SettingsViewModel` from `DesktopUiTestContext` (constructor and DI)
- Update `AppViewModelStateAccessor` — remove `_isDownloadingModel` field access
- Remove `NotReady` state usage from test helpers

## DI Changes (MauiProgram.cs)

- Remove `services.AddSingleton<SettingsViewModel>()`
- Keep all other registrations unchanged

## Migration Safety

- `NotReady` enum value removal is a breaking change — search all usages across Core, CLI, MCP before removing. If other hosts use it, keep the enum value but stop using it in Desktop.
- Routes.razor startup error flow is preserved — if config file is unreadable, the app still shows error + retry.
