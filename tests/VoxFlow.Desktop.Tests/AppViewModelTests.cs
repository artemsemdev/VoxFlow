using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using VoxFlow.Desktop.ViewModels;
using Whisper.net;
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
/// Stub model service for DI compatibility.
/// </summary>
internal sealed class StubModelService : IModelService
{
    public Task<WhisperFactory> GetOrCreateFactoryAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken = default)
    {
        return Task.FromResult<WhisperFactory>(null!);
    }

    public ModelInfo InspectModel(TranscriptionOptions options)
        => new ModelInfo(
            ModelPath: options.ModelFilePath,
            ModelType: options.ModelType,
            Exists: false,
            FileSizeBytes: null,
            IsLoadable: false,
            NeedsDownload: true);
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
            new StubConfigurationService(settingsPath),
            new StubModelService());
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

        Assert.Null(vm.CurrentFileName);

        await vm.TranscribeFileAsync("/tmp/meeting_01.m4a");

        Assert.Equal("meeting_01.m4a", vm.CurrentFileName);
    }

    // -----------------------------------------------------------------------
    // INotifyPropertyChanged — sanity check
    // -----------------------------------------------------------------------

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
}
