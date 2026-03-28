using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using VoxFlow.Desktop.ViewModels;
using Xunit;

namespace VoxFlow.Desktop.Tests;

// ---------------------------------------------------------------------------
// Stub implementations — no mocking library required
// ---------------------------------------------------------------------------

/// <summary>
/// Returns a fixed <see cref="TranscriptionOptions"/> loaded from the root
/// appsettings.json that lives next to the solution file.
/// </summary>
internal sealed class StubConfigurationService : IConfigurationService
{
    private readonly string _settingsPath;

    public StubConfigurationService(string settingsPath)
    {
        _settingsPath = settingsPath;
    }

    public Task<TranscriptionOptions> LoadAsync(string? configurationPath = null)
        => Task.FromResult(TranscriptionOptions.LoadFromPath(configurationPath ?? _settingsPath));

    public IReadOnlyList<SupportedLanguage> GetSupportedLanguages(string? configurationPath = null)
        => LoadAsync(configurationPath).GetAwaiter().GetResult().SupportedLanguages;
}

/// <summary>
/// Returns a configurable <see cref="VoxFlow.Core.Models.ValidationResult"/>.
/// </summary>
internal sealed class StubValidationService : IValidationService
{
    private readonly bool _canStart;

    public StubValidationService(bool canStart)
    {
        _canStart = canStart;
    }

    public Task<ValidationResult> ValidateAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken = default)
    {
        var result = new ValidationResult(
            Outcome: _canStart ? "OK" : "Failed",
            CanStart: _canStart,
            HasWarnings: false,
            ResolvedConfigurationPath: options.ConfigurationPath,
            Checks: Array.Empty<ValidationCheck>());
        return Task.FromResult(result);
    }
}

/// <summary>
/// Returns a configurable <see cref="TranscribeFileResult"/> or throws on demand.
/// </summary>
internal sealed class StubTranscriptionService : ITranscriptionService
{
    private readonly Func<TranscribeFileRequest, TranscribeFileResult>? _factory;
    private readonly Exception? _exception;

    /// <summary>Creates a stub that returns a successful result.</summary>
    public StubTranscriptionService(bool success = true, string[]? warnings = null)
    {
        var w = (IReadOnlyList<string>)(warnings ?? Array.Empty<string>());
        _factory = _ => new TranscribeFileResult(
            Success: success,
            DetectedLanguage: "en",
            ResultFilePath: "/tmp/result.txt",
            AcceptedSegmentCount: 10,
            SkippedSegmentCount: 0,
            Duration: TimeSpan.FromSeconds(5),
            Warnings: w,
            TranscriptPreview: "Hello world");
    }

    /// <summary>Creates a stub that always throws the given exception.</summary>
    public StubTranscriptionService(Exception exception)
    {
        _exception = exception;
    }

    public Task<TranscribeFileResult> TranscribeFileAsync(
        TranscribeFileRequest request,
        IProgress<ProgressUpdate>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (_exception is not null) throw _exception;
        return Task.FromResult(_factory!(request));
    }
}

/// <summary>
/// Blocks until the provided TaskCompletionSource is completed or cancelled.
/// Respects the cancellation token to simulate a cancellable long-running transcription.
/// </summary>
internal sealed class BlockingTranscriptionService : ITranscriptionService
{
    private readonly TaskCompletionSource<TranscribeFileResult> _tcs;

    public BlockingTranscriptionService(TaskCompletionSource<TranscribeFileResult> tcs)
    {
        _tcs = tcs;
    }

    public async Task<TranscribeFileResult> TranscribeFileAsync(
        TranscribeFileRequest request,
        IProgress<ProgressUpdate>? progress = null,
        CancellationToken cancellationToken = default)
    {
        await using var registration = cancellationToken.Register(() => _tcs.TrySetCanceled(cancellationToken));
        return await _tcs.Task;
    }
}

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

internal static class ViewModelFactory
{
    /// <summary>
    /// Resolves the path to the root appsettings.json by walking up from the
    /// test binary output directory until a file named "VoxFlow.sln" is found.
    /// </summary>
    public static string ResolveRootSettingsPath()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null)
        {
            if (dir.GetFiles("VoxFlow.sln").Length > 0)
                return Path.Combine(dir.FullName, "appsettings.json");
            dir = dir.Parent;
        }
        throw new FileNotFoundException(
            "Could not locate VoxFlow.sln while searching upward from: " + AppContext.BaseDirectory);
    }

    public static AppViewModel Create(
        bool validationCanStart = true,
        StubTranscriptionService? transcriptionService = null)
    {
        var settingsPath = ResolveRootSettingsPath();
        return new AppViewModel(
            transcriptionService ?? new StubTranscriptionService(success: true),
            new StubValidationService(validationCanStart),
            new StubConfigurationService(settingsPath));
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

public sealed class AppViewModelTests
{
    // -----------------------------------------------------------------------
    // InitializeAsync
    // -----------------------------------------------------------------------

    [Fact]
    public async Task InitializeAsync_PassingValidation_StateBecomesReady()
    {
        var vm = ViewModelFactory.Create(validationCanStart: true);

        await vm.InitializeAsync();

        Assert.Equal(AppState.Ready, vm.CurrentState);
        Assert.NotNull(vm.ValidationResult);
        Assert.True(vm.ValidationResult!.CanStart);
    }

    [Fact]
    public async Task InitializeAsync_FailingValidation_StillBecomesReady()
    {
        var vm = ViewModelFactory.Create(validationCanStart: false);

        await vm.InitializeAsync();

        Assert.Equal(AppState.Ready, vm.CurrentState);
        Assert.NotNull(vm.ValidationResult);
        Assert.False(vm.ValidationResult!.CanStart);
    }

    // -----------------------------------------------------------------------
    // TranscribeFileAsync — success path
    // -----------------------------------------------------------------------

    [Fact]
    public async Task TranscribeFileAsync_Success_StateBecomesComplete()
    {
        var states = new List<AppState>();
        var vm = ViewModelFactory.Create(transcriptionService: new StubTranscriptionService(success: true));
        await vm.InitializeAsync();
        vm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppViewModel.CurrentState))
                states.Add(vm.CurrentState);
        };

        await vm.TranscribeFileAsync("/tmp/audio.wav");

        // State should have gone through Running then Complete
        Assert.Contains(AppState.Running, states);
        Assert.Equal(AppState.Complete, vm.CurrentState);
        Assert.NotNull(vm.TranscriptionResult);
        Assert.True(vm.TranscriptionResult!.Success);
    }

    // -----------------------------------------------------------------------
    // TranscribeFileAsync — failure result (Success == false)
    // -----------------------------------------------------------------------

    [Fact]
    public async Task TranscribeFileAsync_FailureResult_StateBecomesFailed()
    {
        var vm = ViewModelFactory.Create(
            transcriptionService: new StubTranscriptionService(success: false, warnings: ["low quality"]));
        await vm.InitializeAsync();

        await vm.TranscribeFileAsync("/tmp/audio.wav");

        Assert.Equal(AppState.Failed, vm.CurrentState);
        Assert.NotNull(vm.ErrorMessage);
        Assert.Contains("low quality", vm.ErrorMessage);
    }

    // -----------------------------------------------------------------------
    // TranscribeFileAsync — exception path
    // -----------------------------------------------------------------------

    [Fact]
    public async Task TranscribeFileAsync_Exception_StateBecomesFailedWithMessage()
    {
        var vm = ViewModelFactory.Create(
            transcriptionService: new StubTranscriptionService(new InvalidOperationException("disk full")));
        await vm.InitializeAsync();

        await vm.TranscribeFileAsync("/tmp/audio.wav");

        Assert.Equal(AppState.Failed, vm.CurrentState);
        Assert.Equal("disk full", vm.ErrorMessage);
    }

    // -----------------------------------------------------------------------
    // RetryAsync
    // -----------------------------------------------------------------------

    [Fact]
    public async Task RetryAsync_AfterFailure_RerunsTranscription()
    {
        var vm = ViewModelFactory.Create(
            transcriptionService: new StubTranscriptionService(success: true));
        await vm.InitializeAsync();

        // Trigger a first run so _lastFilePath is populated
        await vm.TranscribeFileAsync("/tmp/audio.wav");
        Assert.Equal(AppState.Complete, vm.CurrentState);

        // Now retry — should reach Complete again
        await vm.RetryAsync();

        Assert.Equal(AppState.Complete, vm.CurrentState);
    }

    [Fact]
    public async Task RetryAsync_WithNoFilePath_DoesNothing()
    {
        var vm = ViewModelFactory.Create();

        // RetryAsync without any prior TranscribeFileAsync call should be a no-op
        await vm.RetryAsync();

        Assert.Equal(AppState.Ready, vm.CurrentState);
    }

    // -----------------------------------------------------------------------
    // GoToReady
    // -----------------------------------------------------------------------

    [Fact]
    public async Task GoToReady_AfterComplete_ResetsState()
    {
        var vm = ViewModelFactory.Create();
        await vm.InitializeAsync();
        await vm.TranscribeFileAsync("/tmp/audio.wav");
        Assert.Equal(AppState.Complete, vm.CurrentState);

        vm.GoToReady();

        Assert.Equal(AppState.Ready, vm.CurrentState);
        Assert.Null(vm.ErrorMessage);
        Assert.Null(vm.TranscriptionResult);
        Assert.Null(vm.CurrentProgress);
    }

    // -----------------------------------------------------------------------
    // CurrentFileName
    // -----------------------------------------------------------------------

    [Fact]
    public async Task CurrentFileName_ReturnsFileNameFromLastPath()
    {
        var vm = ViewModelFactory.Create();
        await vm.InitializeAsync();

        Assert.Null(vm.CurrentFileName);

        await vm.TranscribeFileAsync("/tmp/meeting_01.m4a");

        Assert.Equal("meeting_01.m4a", vm.CurrentFileName);
    }

    // -----------------------------------------------------------------------
    // INotifyPropertyChanged — sanity check
    // -----------------------------------------------------------------------

    [Fact]
    public async Task CancelTranscription_DuringRun_ReturnsToReady()
    {
        var tcs = new TaskCompletionSource<TranscribeFileResult>();
        var blockingVm = new AppViewModel(
            new BlockingTranscriptionService(tcs),
            new StubValidationService(true),
            new StubConfigurationService(ViewModelFactory.ResolveRootSettingsPath()));
        await blockingVm.InitializeAsync();

        // Start transcription (will block)
        var transcribeTask = blockingVm.TranscribeFileAsync("/tmp/audio.wav");
        Assert.Equal(AppState.Running, blockingVm.CurrentState);

        // Cancel
        blockingVm.CancelTranscription();
        tcs.TrySetCanceled();

        await transcribeTask;

        Assert.Equal(AppState.Ready, blockingVm.CurrentState);
        Assert.Null(blockingVm.ErrorMessage);
    }

    [Fact]
    public async Task InitializeAsync_RaisesPropertyChangedForCurrentState()
    {
        var changedProperties = new List<string?>();
        var vm = ViewModelFactory.Create(validationCanStart: true);
        vm.PropertyChanged += (_, e) => changedProperties.Add(e.PropertyName);

        await vm.InitializeAsync();

        Assert.Contains(nameof(AppViewModel.CurrentState), changedProperties);
        Assert.Contains(nameof(AppViewModel.ValidationResult), changedProperties);
    }

    // -----------------------------------------------------------------------
    // B1: Phase 1 — Start guard (A2)
    // -----------------------------------------------------------------------

    [Fact]
    public async Task TranscribeFileAsync_WhenBlockedValidation_DoesNotStart()
    {
        var vm = ViewModelFactory.Create(validationCanStart: false);
        await vm.InitializeAsync();

        await vm.TranscribeFileAsync("/tmp/audio.wav");

        Assert.Equal(AppState.Ready, vm.CurrentState);
        Assert.Null(vm.TranscriptionResult);
    }

    [Fact]
    public async Task TranscribeFileAsync_WhenAlreadyRunning_DoesNotStart()
    {
        var tcs = new TaskCompletionSource<TranscribeFileResult>();
        var blockingVm = new AppViewModel(
            new BlockingTranscriptionService(tcs),
            new StubValidationService(true),
            new StubConfigurationService(ViewModelFactory.ResolveRootSettingsPath()));

        await blockingVm.InitializeAsync();

        // Start first transcription (will block)
        var firstTask = blockingVm.TranscribeFileAsync("/tmp/first.wav");
        Assert.Equal(AppState.Running, blockingVm.CurrentState);

        // Attempt second transcription while running — should be blocked
        await blockingVm.TranscribeFileAsync("/tmp/second.wav");

        // Still running the first one
        Assert.Equal(AppState.Running, blockingVm.CurrentState);
        Assert.Equal("first.wav", blockingVm.CurrentFileName);

        // Clean up
        tcs.TrySetCanceled();
        try { await firstTask; } catch { }
    }

    // -----------------------------------------------------------------------
    // B1: Phase 1 — Transient state clearing (A4)
    // -----------------------------------------------------------------------

    [Fact]
    public async Task TranscribeFileAsync_ClearsTransientStateOnNewRun()
    {
        var vm = ViewModelFactory.Create(transcriptionService: new StubTranscriptionService(success: true));
        await vm.InitializeAsync();

        await vm.TranscribeFileAsync("/tmp/audio.wav");
        Assert.Equal(AppState.Complete, vm.CurrentState);
        Assert.NotNull(vm.TranscriptionResult);

        // Go back to Ready and start a new run — transient state should be cleared during the run
        vm.GoToReady();
        var states = new List<(AppState State, TranscribeFileResult? Result, ProgressUpdate? Progress)>();
        vm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppViewModel.CurrentState) && vm.CurrentState == AppState.Running)
                states.Add((vm.CurrentState, vm.TranscriptionResult, vm.CurrentProgress));
        };

        await vm.TranscribeFileAsync("/tmp/audio2.wav");

        // When entering Running, result and progress should have been cleared
        Assert.NotEmpty(states);
        var (_, result, progress) = states.First();
        Assert.Null(result);
        Assert.Null(progress);
    }

    [Fact]
    public async Task CancelTranscription_ClearsProgressAndResult()
    {
        var tcs = new TaskCompletionSource<TranscribeFileResult>();
        var blockingVm = new AppViewModel(
            new BlockingTranscriptionService(tcs),
            new StubValidationService(true),
            new StubConfigurationService(ViewModelFactory.ResolveRootSettingsPath()));

        await blockingVm.InitializeAsync();
        var transcribeTask = blockingVm.TranscribeFileAsync("/tmp/audio.wav");
        Assert.Equal(AppState.Running, blockingVm.CurrentState);

        blockingVm.CancelTranscription();
        tcs.TrySetCanceled();
        await transcribeTask;

        Assert.Equal(AppState.Ready, blockingVm.CurrentState);
        Assert.Null(blockingVm.CurrentProgress);
        Assert.Null(blockingVm.TranscriptionResult);
        Assert.Null(blockingVm.ErrorMessage);
    }

    // -----------------------------------------------------------------------
    // B1: Phase 1 — CanStart, HasWarnings, WarningMessage (A7)
    // -----------------------------------------------------------------------

    [Fact]
    public async Task CanStart_IsTrueOnlyWhenReadyAndNoBlockingErrors()
    {
        var vm = ViewModelFactory.Create(validationCanStart: true);
        Assert.False(vm.CanStart); // Before initialization, state is Ready but no validation done

        await vm.InitializeAsync();
        Assert.True(vm.CanStart);

        var blockedVm = ViewModelFactory.Create(validationCanStart: false);
        await blockedVm.InitializeAsync();
        Assert.False(blockedVm.CanStart);
    }

    [Fact]
    public async Task HasWarnings_ReflectsValidationWarnings()
    {
        var settingsPath = ViewModelFactory.ResolveRootSettingsPath();
        var warningValidation = new StubValidationServiceWithWarnings();
        var vm = new AppViewModel(
            new StubTranscriptionService(success: true),
            warningValidation,
            new StubConfigurationService(settingsPath));

        await vm.InitializeAsync();

        Assert.True(vm.HasWarnings);
        Assert.NotNull(vm.WarningMessage);
        Assert.Contains("model may be slow", vm.WarningMessage!);
    }
}

/// <summary>
/// Validation service that returns a result with warnings but CanStart == true.
/// </summary>
internal sealed class StubValidationServiceWithWarnings : IValidationService
{
    public Task<ValidationResult> ValidateAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken = default)
    {
        var result = new ValidationResult(
            Outcome: "OK",
            CanStart: true,
            HasWarnings: true,
            ResolvedConfigurationPath: options.ConfigurationPath,
            Checks: [new ValidationCheck("model", ValidationCheckStatus.Warning, "model may be slow")]);
        return Task.FromResult(result);
    }
}
