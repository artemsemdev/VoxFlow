# UI Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Simplify the VoxFlow Desktop UI to 3 screens (Ready, Running, Complete) by removing NotReady state, SettingsPanel, StatusBar, and settings toggle.

**Architecture:** Remove configuration/validation UI. App starts directly in Ready state. Errors surface at transcription time via Failed state. SettingsViewModel and related components are deleted.

**Tech Stack:** .NET 9, MAUI Blazor Hybrid, Razor components, CSS, xUnit

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Modify | `src/VoxFlow.Core/Models/AppState.cs` | Remove `NotReady` enum value |
| Modify | `src/VoxFlow.Desktop/ViewModels/AppViewModel.cs` | Simplify state machine, add GoToReady/CurrentFileName, remove download/revalidate |
| Delete | `src/VoxFlow.Desktop/ViewModels/SettingsViewModel.cs` | No longer needed |
| Modify | `src/VoxFlow.Desktop/MauiProgram.cs` | Remove SettingsViewModel DI registration |
| Modify | `src/VoxFlow.Desktop/Components/Routes.razor` | Update recovery text |
| Modify | `src/VoxFlow.Desktop/Components/Layout/MainLayout.razor` | Remove header, status bar, settings panel |
| Modify | `src/VoxFlow.Desktop/Components/Pages/ReadyView.razor` | New mockup layout |
| Modify | `src/VoxFlow.Desktop/Components/Pages/RunningView.razor` | File card with progress |
| Modify | `src/VoxFlow.Desktop/Components/Pages/CompleteView.razor` | Back arrow, transcript, buttons |
| Modify | `src/VoxFlow.Desktop/Components/Pages/FailedView.razor` | Use GoToReady |
| Modify | `src/VoxFlow.Desktop/Components/Shared/DropZone.razor` | Update icon and text |
| Delete | `src/VoxFlow.Desktop/Components/Pages/NotReadyView.razor` | No longer needed |
| Delete | `src/VoxFlow.Desktop/Components/Shared/SettingsPanel.razor` | No longer needed |
| Delete | `src/VoxFlow.Desktop/Components/Shared/StatusBar.razor` | No longer needed |
| Modify | `src/VoxFlow.Desktop/wwwroot/css/app.css` | Remove old CSS, add new card styles |
| Modify | `tests/VoxFlow.Desktop.Tests/AppViewModelTests.cs` | Update/remove tests for new state machine |
| Modify | `tests/VoxFlow.Desktop.Tests/DesktopUiComponentTests.cs` | Update/remove tests for new UI |
| Modify | `tests/VoxFlow.Desktop.Tests/Infrastructure/UiTestInfrastructure.cs` | Remove SettingsViewModel from test context |

---

### Task 1: Simplify AppState enum and AppViewModel

**Files:**
- Modify: `src/VoxFlow.Core/Models/AppState.cs`
- Modify: `src/VoxFlow.Desktop/ViewModels/AppViewModel.cs`

- [ ] **Step 1: Remove `NotReady` from AppState enum**

In `src/VoxFlow.Core/Models/AppState.cs`, change to:

```csharp
namespace VoxFlow.Core.Models;

public enum AppState
{
    Ready,
    Running,
    Failed,
    Complete
}
```

- [ ] **Step 2: Simplify AppViewModel**

In `src/VoxFlow.Desktop/ViewModels/AppViewModel.cs`, apply these changes:

1. Change default state from `AppState.NotReady` to `AppState.Ready`
2. In `InitializeAsync()`, always set state to `Ready` (remove NotReady branch)
3. Add `CurrentFileName` computed property
4. Add `GoToReady()` method
5. Remove `IsDownloadingModel` property, `_isDownloadingModel` field, `DownloadModelAsync()` method, `RevalidateAsync()` method

Replace the entire file with:

```csharp
using System.ComponentModel;
using System.Runtime.CompilerServices;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using VoxFlow.Desktop.Services;

namespace VoxFlow.Desktop.ViewModels;

public class AppViewModel : INotifyPropertyChanged
{
    private readonly ITranscriptionService _transcriptionService;
    private readonly IValidationService _validationService;
    private readonly IConfigurationService _configService;

    private AppState _currentState = AppState.Ready;
    private ValidationResult? _validationResult;
    private TranscribeFileResult? _transcriptionResult;
    private ProgressUpdate? _currentProgress;
    private string? _errorMessage;
    private string? _lastFilePath;
    private CancellationTokenSource? _cts;

    public AppViewModel(
        ITranscriptionService transcriptionService,
        IValidationService validationService,
        IConfigurationService configService,
        IModelService modelService)
    {
        _transcriptionService = transcriptionService;
        _validationService = validationService;
        _configService = configService;
    }

    public AppState CurrentState
    {
        get => _currentState;
        private set { _currentState = value; OnPropertyChanged(); }
    }

    public ValidationResult? ValidationResult
    {
        get => _validationResult;
        private set { _validationResult = value; OnPropertyChanged(); }
    }

    public TranscribeFileResult? TranscriptionResult
    {
        get => _transcriptionResult;
        private set { _transcriptionResult = value; OnPropertyChanged(); }
    }

    public ProgressUpdate? CurrentProgress
    {
        get => _currentProgress;
        set { _currentProgress = value; OnPropertyChanged(); }
    }

    public string? ErrorMessage
    {
        get => _errorMessage;
        private set { _errorMessage = value; OnPropertyChanged(); }
    }

    public string? CurrentFileName => _lastFilePath is not null ? Path.GetFileName(_lastFilePath) : null;

    public async Task InitializeAsync()
    {
        var options = await _configService.LoadAsync();
        var result = await _validationService.ValidateAsync(options);
        ValidationResult = result;
        CurrentState = AppState.Ready;
    }

    public async Task TranscribeFileAsync(string filePath)
    {
        _lastFilePath = filePath;
        OnPropertyChanged(nameof(CurrentFileName));
        CurrentState = AppState.Running;
        ErrorMessage = null;
        _cts = new CancellationTokenSource();
        var progress = new BlazorProgressHandler(this);
        try
        {
            var request = new TranscribeFileRequest(filePath);
            TranscriptionResult = await _transcriptionService.TranscribeFileAsync(request, progress, _cts.Token);
            CurrentState = TranscriptionResult.Success ? AppState.Complete : AppState.Failed;
            if (!TranscriptionResult.Success)
                ErrorMessage = string.Join("; ", TranscriptionResult.Warnings);
        }
        catch (OperationCanceledException) { CurrentState = AppState.Ready; }
        catch (Exception ex) { ErrorMessage = ex.Message; CurrentState = AppState.Failed; }
    }

    public async Task RetryAsync()
    {
        if (_lastFilePath != null) await TranscribeFileAsync(_lastFilePath);
    }

    public void GoToReady()
    {
        CurrentState = AppState.Ready;
        ErrorMessage = null;
        TranscriptionResult = null;
        CurrentProgress = null;
    }

    public void CancelTranscription() => _cts?.Cancel();

    public event PropertyChangedEventHandler? PropertyChanged;
    public void NotifyStateChanged() => OnPropertyChanged(string.Empty);
    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
```

- [ ] **Step 3: Verify the project compiles (expect errors from deleted references — that's OK for now)**

Run: `dotnet build src/VoxFlow.Core/VoxFlow.Core.csproj`
Expected: SUCCESS

- [ ] **Step 4: Commit**

```bash
git add src/VoxFlow.Core/Models/AppState.cs src/VoxFlow.Desktop/ViewModels/AppViewModel.cs
git commit -m "refactor: simplify AppState enum and AppViewModel for new UI"
```

---

### Task 2: Delete removed components and SettingsViewModel

**Files:**
- Delete: `src/VoxFlow.Desktop/ViewModels/SettingsViewModel.cs`
- Delete: `src/VoxFlow.Desktop/Components/Pages/NotReadyView.razor`
- Delete: `src/VoxFlow.Desktop/Components/Shared/SettingsPanel.razor`
- Delete: `src/VoxFlow.Desktop/Components/Shared/StatusBar.razor`
- Modify: `src/VoxFlow.Desktop/MauiProgram.cs`

- [ ] **Step 1: Delete the 4 files**

```bash
rm src/VoxFlow.Desktop/ViewModels/SettingsViewModel.cs
rm src/VoxFlow.Desktop/Components/Pages/NotReadyView.razor
rm src/VoxFlow.Desktop/Components/Shared/SettingsPanel.razor
rm src/VoxFlow.Desktop/Components/Shared/StatusBar.razor
```

- [ ] **Step 2: Remove SettingsViewModel DI registration from MauiProgram.cs**

In `src/VoxFlow.Desktop/MauiProgram.cs`, remove the line:
```csharp
builder.Services.AddSingleton<SettingsViewModel>();
```

The file should become:

```csharp
using VoxFlow.Core.DependencyInjection;
using VoxFlow.Core.Interfaces;
using VoxFlow.Desktop.Configuration;
using VoxFlow.Desktop.ViewModels;

namespace VoxFlow.Desktop;

public static class MauiProgram
{
    public static MauiApp CreateMauiApp()
    {
        var builder = MauiApp.CreateBuilder();
        builder
            .UseMauiApp<App>()
            .ConfigureFonts(fonts =>
            {
                fonts.AddFont("OpenSans-Regular.ttf", "OpenSansRegular");
            });

        builder.Services.AddMauiBlazorWebView();
        builder.Services.AddVoxFlowCore();
        builder.Services.AddSingleton<IConfigurationService, DesktopConfigurationService>();
        builder.Services.AddSingleton<AppViewModel>();
        builder.Services.AddSingleton<MainPage>();

        return builder.Build();
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor: delete NotReadyView, SettingsPanel, StatusBar, SettingsViewModel"
```

---

### Task 3: Update MainLayout and Routes

**Files:**
- Modify: `src/VoxFlow.Desktop/Components/Layout/MainLayout.razor`
- Modify: `src/VoxFlow.Desktop/Components/Routes.razor`

- [ ] **Step 1: Simplify MainLayout**

Replace `src/VoxFlow.Desktop/Components/Layout/MainLayout.razor` with:

```razor
@inherits LayoutComponentBase
@inject AppViewModel ViewModel

<div class="app-shell">
    <main class="app-content">
        @switch (ViewModel.CurrentState)
        {
            case AppState.Ready:
                <ReadyView />
                break;
            case AppState.Running:
                <RunningView />
                break;
            case AppState.Failed:
                <FailedView />
                break;
            case AppState.Complete:
                <CompleteView />
                break;
        }
    </main>
</div>
```

- [ ] **Step 2: Update Routes.razor recovery text**

In `src/VoxFlow.Desktop/Components/Routes.razor`, the startup error recovery flow stays the same. No code changes needed — the existing flow catches config load errors and shows Retry. After retry succeeds, `InitializeAsync()` now always sets `Ready`, so it will show ReadyView with "Audio Transcription" title.

- [ ] **Step 3: Commit**

```bash
git add src/VoxFlow.Desktop/Components/Layout/MainLayout.razor src/VoxFlow.Desktop/Components/Routes.razor
git commit -m "refactor: simplify MainLayout - remove header, status bar, settings"
```

---

### Task 4: Redesign ReadyView and DropZone

**Files:**
- Modify: `src/VoxFlow.Desktop/Components/Pages/ReadyView.razor`
- Modify: `src/VoxFlow.Desktop/Components/Shared/DropZone.razor`

- [ ] **Step 1: Update ReadyView to match mockup**

Replace `src/VoxFlow.Desktop/Components/Pages/ReadyView.razor` with:

```razor
@inject AppViewModel ViewModel

<div class="text-center">
    <h1 class="app-main-title">Audio Transcription</h1>
    <p class="text-secondary mt-2">Drop your M4A files here to convert speech into text</p>
</div>

<div class="mt-6">
    <DropZone OnFileSelected="HandleFileSelected" />
</div>

<p class="text-muted mt-4 text-center supported-formats">
    Supported format: M4A. You can upload multiple files.
</p>

@code {
    private async Task HandleFileSelected(string filePath)
    {
        await ViewModel.TranscribeFileAsync(filePath);
    }
}
```

- [ ] **Step 2: Update DropZone to match mockup**

Replace `src/VoxFlow.Desktop/Components/Shared/DropZone.razor` with:

```razor
@using VoxFlow.Desktop.Platform

<div class="drop-zone"
     role="button"
     tabindex="0"
     @onclick="BrowseFiles"
     @onkeydown="HandleKeyDown">

    <div class="upload-icon">
        <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
            <polyline points="17 8 12 3 7 8"/>
            <line x1="12" y1="3" x2="12" y2="15"/>
        </svg>
    </div>
    <span class="drop-label">@(Label ?? "No files added yet")</span>
    <span class="drop-hint">Drop your M4A files here or <span class="drop-browse-link">browse</span> from your device.</span>
    <button class="btn btn-primary mt-4"
            @onclick="BrowseFiles"
            @onclick:stopPropagation="true">
        + Browse Files
    </button>
</div>

@if (!string.IsNullOrWhiteSpace(_selectionError))
{
    <div class="message message-error mt-4">
        <span class="message-icon">✗</span>
        <span>@_selectionError</span>
    </div>
}

@code {
    [Parameter]
    public EventCallback<string> OnFileSelected { get; set; }

    [Parameter]
    public string? Label { get; set; }

    private string? _selectionError;

    private async Task BrowseFiles()
    {
        _selectionError = null;

        try
        {
            var filePath = await MacFilePicker.PickAudioFileAsync();
            if (!string.IsNullOrWhiteSpace(filePath))
            {
                await OnFileSelected.InvokeAsync(filePath);
            }
        }
        catch (Exception ex)
        {
            _selectionError = $"File picker failed: {ex.Message}";
        }
    }

    private async Task HandleKeyDown(KeyboardEventArgs args)
    {
        if (args.Key is "Enter" or " ")
        {
            await BrowseFiles();
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add src/VoxFlow.Desktop/Components/Pages/ReadyView.razor src/VoxFlow.Desktop/Components/Shared/DropZone.razor
git commit -m "feat: redesign ReadyView and DropZone to match new mockup"
```

---

### Task 5: Redesign RunningView

**Files:**
- Modify: `src/VoxFlow.Desktop/Components/Pages/RunningView.razor`

- [ ] **Step 1: Update RunningView to file card layout**

Replace `src/VoxFlow.Desktop/Components/Pages/RunningView.razor` with:

```razor
@inject AppViewModel ViewModel

<div class="file-card">
    <div class="file-card-header">
        <div class="file-card-info">
            <div class="file-card-icon">▶</div>
            <span class="file-card-name">@(ViewModel.CurrentFileName ?? "audio file")</span>
        </div>
    </div>

    @if (ViewModel.CurrentProgress is not null)
    {
        <div class="progress-container">
            <div class="progress-track">
                <div class="progress-bar"
                     style="width: @($"{ViewModel.CurrentProgress.PercentComplete:F0}%")">
                </div>
            </div>
        </div>

        <p class="file-card-stage">
            <span class="file-card-stage-label">@ViewModel.CurrentProgress.Stage:</span>
            @ViewModel.CurrentProgress.Message
        </p>

        @if (!string.IsNullOrEmpty(ViewModel.CurrentProgress.CurrentLanguage))
        {
            <p class="text-muted mt-2">Language: @ViewModel.CurrentProgress.CurrentLanguage</p>
        }
    }
    else
    {
        <div class="mt-4">
            <div class="spinner spinner-lg"></div>
        </div>
    }
</div>

@if (ViewModel.CurrentProgress is not null)
{
    <p class="text-muted mt-4 text-center">
        Elapsed Time: <span class="text-secondary">@FormatElapsed(ViewModel.CurrentProgress.Elapsed)</span>
    </p>
}

<div class="btn-group mt-4">
    <button class="btn btn-secondary" @onclick="ViewModel.CancelTranscription">
        Cancel
    </button>
</div>

@code {
    private static string FormatElapsed(TimeSpan elapsed)
    {
        if (elapsed.TotalHours >= 1)
            return elapsed.ToString(@"hh\:mm\:ss");
        return elapsed.ToString(@"mm\:ss");
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add src/VoxFlow.Desktop/Components/Pages/RunningView.razor
git commit -m "feat: redesign RunningView with file card layout"
```

---

### Task 6: Redesign CompleteView

**Files:**
- Modify: `src/VoxFlow.Desktop/Components/Pages/CompleteView.razor`

- [ ] **Step 1: Update CompleteView to match mockup**

Replace `src/VoxFlow.Desktop/Components/Pages/CompleteView.razor` with:

```razor
@inject AppViewModel ViewModel
@inject IJSRuntime JSRuntime

<div class="result-header">
    <div class="result-header-left">
        <button class="result-back-btn" @onclick="ViewModel.GoToReady">‹</button>
        <span class="result-filename">@(ViewModel.CurrentFileName ?? "result")</span>
    </div>
</div>

@if (ViewModel.TranscriptionResult is not null)
{
    var result = ViewModel.TranscriptionResult;

    @if (!string.IsNullOrEmpty(result.DetectedLanguage))
    {
        <p class="result-language">Language: @result.DetectedLanguage</p>
    }

    @if (!string.IsNullOrEmpty(result.TranscriptPreview))
    {
        <div class="transcript-preview mt-4">@result.TranscriptPreview</div>
    }
}

<div class="btn-group mt-4">
    <button class="btn btn-secondary" @onclick="OpenFolder">
        Open Folder
    </button>
    <button class="btn btn-secondary" @onclick="CopyTranscript">
        @(_copied ? "Copied!" : "Copy Text")
    </button>
</div>

@code {
    private bool _copied;

    private async Task OpenFolder()
    {
        var result = ViewModel.TranscriptionResult;
        if (result is not null && !string.IsNullOrEmpty(result.ResultFilePath))
        {
            var directory = Path.GetDirectoryName(result.ResultFilePath);
            if (!string.IsNullOrEmpty(directory))
            {
                await Launcher.Default.OpenAsync(directory);
            }
        }
    }

    private async Task CopyTranscript()
    {
        var result = ViewModel.TranscriptionResult;
        if (result is not null && !string.IsNullOrEmpty(result.TranscriptPreview))
        {
            await JSRuntime.InvokeVoidAsync("voxFlowInterop.copyToClipboard", result.TranscriptPreview);
            _copied = true;
            StateHasChanged();

            _ = Task.Delay(2000).ContinueWith(_ =>
            {
                _copied = false;
                InvokeAsync(StateHasChanged);
            });
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add src/VoxFlow.Desktop/Components/Pages/CompleteView.razor
git commit -m "feat: redesign CompleteView with back navigation and clean layout"
```

---

### Task 7: Update FailedView

**Files:**
- Modify: `src/VoxFlow.Desktop/Components/Pages/FailedView.razor`

- [ ] **Step 1: Update FailedView to use GoToReady**

Replace `src/VoxFlow.Desktop/Components/Pages/FailedView.razor` with:

```razor
@inject AppViewModel ViewModel

<div class="text-center">
    <h2>Transcription Failed</h2>
</div>

@if (!string.IsNullOrEmpty(ViewModel.ErrorMessage))
{
    <div class="message message-error mt-4">
        <span class="message-icon">✗</span>
        <span>@ViewModel.ErrorMessage</span>
    </div>
}

<div class="btn-group mt-6">
    <button class="btn btn-primary" @onclick="ViewModel.RetryAsync">
        Retry
    </button>
    <button class="btn btn-secondary" @onclick="ViewModel.GoToReady">
        Choose Different File
    </button>
</div>
```

- [ ] **Step 2: Commit**

```bash
git add src/VoxFlow.Desktop/Components/Pages/FailedView.razor
git commit -m "refactor: update FailedView to use GoToReady"
```

---

### Task 8: Update CSS

**Files:**
- Modify: `src/VoxFlow.Desktop/wwwroot/css/app.css`

- [ ] **Step 1: Remove unused CSS sections**

Remove the following CSS blocks from `app.css`:
- `.settings-toggle` and hover/active states (lines 89-113)
- `.settings-overlay`, `.settings-panel`, `@keyframes slide-in-right`, `@keyframes fade-in`, `.settings-header`, `.settings-close`, `.settings-body`, `.settings-group` (lines 298-405)
- `.status-bar`, `.status-indicator`, `.status-dot`, `.status-dot.status-ok/warning/error`, `.status-ok`, `.status-warning`, `.status-error` (lines 241-296)
- `.validation-checklist`, `.validation-item`, `.validation-icon`, `.validation-label`, `.validation-detail` (lines 407-458)

- [ ] **Step 2: Add new CSS for redesigned components**

Add the following CSS to `app.css`:

```css
/* ---------- App Main Title ---------- */
.app-main-title {
    font-size: 28px;
    font-weight: 700;
    color: var(--text-primary);
    letter-spacing: -0.5px;
}

/* ---------- Upload Icon ---------- */
.upload-icon {
    width: 64px;
    height: 64px;
    margin: 0 auto 16px;
    background: rgba(74, 74, 255, 0.1);
    border-radius: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--accent);
}

/* ---------- Drop Zone Browse Link ---------- */
.drop-browse-link {
    color: var(--accent);
    cursor: pointer;
}

/* ---------- Supported Formats ---------- */
.supported-formats {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

/* ---------- File Card (Running View) ---------- */
.file-card {
    width: 100%;
    max-width: 480px;
    padding: 20px;
    background: rgba(22, 33, 62, 0.6);
    border: 1px solid var(--border);
    border-radius: 10px;
}

.file-card-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 16px;
}

.file-card-info {
    display: flex;
    align-items: center;
    gap: 10px;
}

.file-card-icon {
    width: 32px;
    height: 32px;
    background: rgba(74, 74, 255, 0.15);
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--accent);
    font-size: 14px;
}

.file-card-name {
    color: var(--text-primary);
    font-size: 14px;
    font-weight: 500;
}

.file-card-stage {
    margin-top: 8px;
    font-size: 12px;
    color: var(--text-secondary);
}

.file-card-stage-label {
    font-weight: 500;
}

/* ---------- Result Header (Complete View) ---------- */
.result-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    width: 100%;
    max-width: 600px;
    margin-bottom: 4px;
}

.result-header-left {
    display: flex;
    align-items: center;
    gap: 12px;
}

.result-back-btn {
    background: transparent;
    border: none;
    color: var(--text-secondary);
    font-size: 24px;
    cursor: pointer;
    padding: 4px 8px;
    border-radius: 6px;
    transition: background var(--transition-fast), color var(--transition-fast);
}

.result-back-btn:hover {
    background: rgba(255, 255, 255, 0.06);
    color: var(--text-primary);
}

.result-filename {
    color: var(--text-primary);
    font-size: 16px;
    font-weight: 600;
}

.result-language {
    color: var(--accent);
    font-size: 12px;
    margin-left: 44px;
}
```

- [ ] **Step 3: Update app-header CSS to remove header height from layout**

In the `.app-shell` section, the header is no longer rendered so no changes needed there. But remove the `.app-header` CSS block since it's no longer used:

Remove the `/* ---------- App Header ---------- */` section including `.app-header`, `.app-title`.

- [ ] **Step 4: Commit**

```bash
git add src/VoxFlow.Desktop/wwwroot/css/app.css
git commit -m "style: update CSS for simplified UI - remove old styles, add new components"
```

---

### Task 9: Update AppViewModelTests

**Files:**
- Modify: `tests/VoxFlow.Desktop.Tests/AppViewModelTests.cs`

- [ ] **Step 1: Remove tests for deleted functionality**

Remove these tests:
- `InitializeAsync_FailingValidation_StateBecomesNotReady` — NotReady state no longer exists
- `DownloadModelAsync_CallsModelServiceAndRevalidates` — method removed

- [ ] **Step 2: Update test for RetryAsync default state**

In `RetryAsync_WithNoFilePath_DoesNothing`, change assertion from `AppState.NotReady` to `AppState.Ready`:

```csharp
[Fact]
public async Task RetryAsync_WithNoFilePath_DoesNothing()
{
    var vm = ViewModelFactory.Create();

    await vm.RetryAsync();

    Assert.Equal(AppState.Ready, vm.CurrentState);
}
```

- [ ] **Step 3: Remove `CreateWithModelService` helper and `StubModelService.GetOrCreateFactoryWasCalled`**

In `ViewModelFactory`, remove the `CreateWithModelService` method since no test uses it anymore.

- [ ] **Step 4: Add test for GoToReady**

```csharp
[Fact]
public async Task GoToReady_AfterComplete_ResetsState()
{
    var vm = ViewModelFactory.Create();
    await vm.TranscribeFileAsync("/tmp/audio.wav");
    Assert.Equal(AppState.Complete, vm.CurrentState);

    vm.GoToReady();

    Assert.Equal(AppState.Ready, vm.CurrentState);
    Assert.Null(vm.ErrorMessage);
    Assert.Null(vm.TranscriptionResult);
    Assert.Null(vm.CurrentProgress);
}
```

- [ ] **Step 5: Add test for CurrentFileName**

```csharp
[Fact]
public async Task CurrentFileName_ReturnsFileNameFromLastPath()
{
    var vm = ViewModelFactory.Create();

    Assert.Null(vm.CurrentFileName);

    await vm.TranscribeFileAsync("/tmp/meeting_01.m4a");

    Assert.Equal("meeting_01.m4a", vm.CurrentFileName);
}
```

- [ ] **Step 6: Run tests**

Run: `dotnet test tests/VoxFlow.Desktop.Tests/ --filter "FullyQualifiedName~AppViewModelTests" -v n`
Expected: All tests PASS

- [ ] **Step 7: Commit**

```bash
git add tests/VoxFlow.Desktop.Tests/AppViewModelTests.cs
git commit -m "test: update AppViewModelTests for simplified state machine"
```

---

### Task 10: Update UI test infrastructure

**Files:**
- Modify: `tests/VoxFlow.Desktop.Tests/Infrastructure/UiTestInfrastructure.cs`

- [ ] **Step 1: Remove SettingsViewModel from DesktopUiTestContext**

In `DesktopUiTestContext`:
1. Remove `SettingsViewModel Settings` property from constructor and class
2. Remove `services.AddSingleton(settings)` from `Create()` method
3. Remove `var settings = new SettingsViewModel(config)` from `Create()` method
4. Remove `settings` parameter from constructor call
5. In `CreateWithRealCore()`: remove `services.AddSingleton<SettingsViewModel>()`, remove `SettingsViewModel` from constructor call

Update constructor:
```csharp
public DesktopUiTestContext(
    TestRenderer renderer,
    AppViewModel viewModel,
    RecordingJsRuntime jsRuntime,
    ITranscriptionService transcriptionService)
{
    Renderer = renderer;
    ViewModel = viewModel;
    JsRuntime = jsRuntime;
    TranscriptionService = transcriptionService;
}
```

- [ ] **Step 2: Update AppViewModelStateAccessor — remove `_isDownloadingModel`**

In `SetState` method, remove the `isDownloadingModel` parameter and the `SetIfProvided` call for `_isDownloadingModel`.

```csharp
internal static class AppViewModelStateAccessor
{
    public static void SetState(
        AppViewModel viewModel,
        AppState? currentState = null,
        ValidationResult? validationResult = null,
        TranscribeFileResult? transcriptionResult = null,
        ProgressUpdate? currentProgress = null,
        string? errorMessage = null,
        string? lastFilePath = null)
    {
        SetIfProvided(viewModel, "_currentState", currentState);
        SetIfProvided(viewModel, "_validationResult", validationResult);
        SetIfProvided(viewModel, "_transcriptionResult", transcriptionResult);
        SetIfProvided(viewModel, "_currentProgress", currentProgress);
        SetIfProvided(viewModel, "_errorMessage", errorMessage);
        SetIfProvided(viewModel, "_lastFilePath", lastFilePath);
        viewModel.NotifyStateChanged();
    }

    // ... SetIfProvided stays the same
}
```

- [ ] **Step 3: Commit**

```bash
git add tests/VoxFlow.Desktop.Tests/Infrastructure/UiTestInfrastructure.cs
git commit -m "test: update UI test infrastructure - remove SettingsViewModel, simplify"
```

---

### Task 11: Update DesktopUiComponentTests

**Files:**
- Modify: `tests/VoxFlow.Desktop.Tests/DesktopUiComponentTests.cs`

- [ ] **Step 1: Remove tests for deleted components**

Remove these tests:
- `MainLayout_SettingsToggle_OpensSettingsPanel`
- `NotReadyView_RendersRecoveryActions_ForFailedChecks`
- `StatusBar_WithoutValidation_ShowsInitializingState`
- `SettingsPanel_LoadsConfiguredValues_AndSaveClosesPanel`

Also remove the `using` for `SettingsPanel`/`NotReadyView`/`StatusBar` if they cause compile errors (they are referenced via Razor `@using` directives typically, but check the imports at the top of the test file).

- [ ] **Step 2: Update Routes startup error recovery test**

In `Routes_WhenInitializationFails_ShowsStartupError_AndRetryRecovers`, change the final assertion from:
```csharp
Assert.Contains("Ready to Transcribe", rendered.TextContent);
```
to:
```csharp
Assert.Contains("Audio Transcription", rendered.TextContent);
```

- [ ] **Step 3: Update RunningView test**

In `RunningView_WithProgress_ShowsDetailedProgress`, update assertions to match new layout. The test still checks progress percentage and text, but heading text changed:

Change:
```csharp
Assert.Contains("Transcribing...", rendered.TextContent);
```
to:
```csharp
Assert.Contains("audio file", rendered.TextContent);
```

(Since CurrentFileName is null in this test — no TranscribeFileAsync was called — it falls back to "audio file".)

Keep the other assertions (`Processing audio`, `Language: English`, `2:05`, progress bar 42%) as they still apply.

- [ ] **Step 4: Update CompleteView copy test**

In `CompleteView_CopyTranscript_UsesClipboardInterop_AndUpdatesButton`, change:
```csharp
await rendered.ClickAsync(
    element => element.Name == "button" && element.TextContent == "Copy Transcript",
    "copy transcript button");
```
to:
```csharp
await rendered.ClickAsync(
    element => element.Name == "button" && element.TextContent == "Copy Text",
    "copy text button");
```

- [ ] **Step 5: Update FailedView tests assertions**

In `FailedMainLayout_ChooseDifferentFile_Revalidates_ToReady` (still skipped), update:
```csharp
Assert.Contains("Ready to Transcribe", rendered.TextContent);
```
to:
```csharp
Assert.Contains("Audio Transcription", rendered.TextContent);
```

In `FailedMainLayout_Retry_UsesLastFile_AndTransitions_ToComplete` (still skipped), the test clicks "Retry" and checks for complete. Update:
```csharp
Assert.Contains("Transcription Complete", rendered.TextContent);
```
to:
```csharp
Assert.NotNull(context.ViewModel.TranscriptionResult);
Assert.True(context.ViewModel.TranscriptionResult!.Success);
```

- [ ] **Step 6: Update real audio integration tests**

In `Routes_BrowseFile_WithRealAudio_CompletesTranscription`, change:
```csharp
Assert.Contains("Transcription Complete", rendered.TextContent);
```
to:
```csharp
Assert.Contains(Path.GetFileName(inputPath), rendered.TextContent);
```

The `Browse Files` button text is the same in the new DropZone, so that assertion stays.

- [ ] **Step 7: Add test for CompleteView back button**

```csharp
[Fact]
public async Task CompleteView_BackButton_NavigatesToReady()
{
    await using var context = DesktopUiTestContext.Create();
    AppViewModelStateAccessor.SetState(
        context.ViewModel,
        currentState: AppState.Complete,
        transcriptionResult: new TranscribeFileResult(
            Success: true,
            DetectedLanguage: "en",
            ResultFilePath: "/tmp/result.txt",
            AcceptedSegmentCount: 7,
            SkippedSegmentCount: 0,
            Duration: TimeSpan.FromSeconds(12),
            Warnings: [],
            TranscriptPreview: "Test text"));

    var rendered = await context.RenderAsync<CompleteView>();

    await rendered.ClickAsync(
        element => element.Name == "button" && element.HasClass("result-back-btn"),
        "back button");

    Assert.Equal(AppState.Ready, context.ViewModel.CurrentState);
}
```

- [ ] **Step 8: Run all Desktop UI tests**

Run: `dotnet test tests/VoxFlow.Desktop.Tests/ --filter "FullyQualifiedName~DesktopUiComponentTests" -v n`
Expected: All non-skipped tests PASS

- [ ] **Step 9: Commit**

```bash
git add tests/VoxFlow.Desktop.Tests/DesktopUiComponentTests.cs
git commit -m "test: update UI component tests for simplified interface"
```

---

### Task 12: Final verification

- [ ] **Step 1: Run full Desktop test suite**

Run: `dotnet test tests/VoxFlow.Desktop.Tests/ -v n`
Expected: All non-skipped tests PASS

- [ ] **Step 2: Build the entire solution**

Run: `dotnet build`
Expected: SUCCESS with no errors

- [ ] **Step 3: Run all tests across the solution**

Run: `dotnet test -v n`
Expected: All non-skipped tests PASS

- [ ] **Step 4: Commit any remaining fixes if needed**

```bash
git add -A
git commit -m "fix: resolve any remaining build/test issues from UI simplification"
```
