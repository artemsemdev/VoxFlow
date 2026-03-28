using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using VoxFlow.Desktop.Services;

namespace VoxFlow.Desktop.ViewModels;

/// <summary>
/// Coordinates the desktop UI state machine for single-file transcription.
/// </summary>
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
        IConfigurationService configService)
    {
        ArgumentNullException.ThrowIfNull(transcriptionService);
        ArgumentNullException.ThrowIfNull(validationService);
        ArgumentNullException.ThrowIfNull(configService);

        _transcriptionService = transcriptionService;
        _validationService = validationService;
        _configService = configService;
    }

    public AppState CurrentState
    {
        get => _currentState;
        private set { _currentState = value; OnPropertyChanged(); OnPropertyChanged(nameof(CanStart)); }
    }

    public ValidationResult? ValidationResult
    {
        get => _validationResult;
        private set
        {
            _validationResult = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(HasBlockingValidationErrors));
            OnPropertyChanged(nameof(BlockingValidationMessage));
            OnPropertyChanged(nameof(HasWarnings));
            OnPropertyChanged(nameof(WarningMessage));
            OnPropertyChanged(nameof(CanStart));
        }
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

    public bool HasBlockingValidationErrors => ValidationResult?.CanStart == false;

    public bool HasWarnings => ValidationResult?.HasWarnings == true && ValidationResult.CanStart;

    public string? BlockingValidationMessage => ValidationResult?.Checks is null
        ? null
        : string.Join(
            "; ",
            ValidationResult.Checks
                .Where(check => check.Status == ValidationCheckStatus.Failed)
                .Select(check => check.Details));

    public string? WarningMessage => ValidationResult?.Checks is null
        ? null
        : string.Join(
            "; ",
            ValidationResult.Checks
                .Where(check => check.Status == ValidationCheckStatus.Warning)
                .Select(check => check.Details));

    public bool CanStart => CurrentState == AppState.Ready && ValidationResult is not null && !HasBlockingValidationErrors;

    public string? CurrentFileName => _lastFilePath is not null ? Path.GetFileName(_lastFilePath) : null;

    /// <summary>
    /// Reads the full transcript from the result file when available.
    /// Falls back to the preview if the file cannot be read.
    /// </summary>
    public string? GetFullTranscript()
    {
        var result = TranscriptionResult;
        if (result is null)
            return null;

        if (!string.IsNullOrEmpty(result.ResultFilePath) && File.Exists(result.ResultFilePath))
        {
            try
            {
                return File.ReadAllText(result.ResultFilePath);
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[AppViewModel] Failed to read full transcript: {ex.Message}");
            }
        }

        return result.TranscriptPreview;
    }

    /// <summary>
    /// Loads effective configuration, runs startup validation, and initializes the UI state.
    /// </summary>
    public async Task InitializeAsync()
    {
        var options = await _configService.LoadAsync();
        var result = await _validationService.ValidateAsync(options);
        ValidationResult = result;
        CurrentState = AppState.Ready;
    }

    /// <summary>
    /// Starts transcription for the selected file and updates the UI as progress changes.
    /// Guards against invalid states: only starts when <see cref="CanStart"/> is true.
    /// </summary>
    public async Task TranscribeFileAsync(string filePath)
    {
        if (!CanStart)
        {
            System.Diagnostics.Debug.WriteLine($"[AppViewModel] TranscribeFileAsync blocked: CanStart={CanStart}, State={CurrentState}");
            return;
        }

        System.Diagnostics.Debug.WriteLine($"[AppViewModel] TranscribeFileAsync started: {filePath}");
        _lastFilePath = filePath;
        OnPropertyChanged(nameof(CurrentFileName));
        TranscriptionResult = null;
        CurrentProgress = null;
        ErrorMessage = null;
        CurrentState = AppState.Running;
        _cts?.Dispose();
        var cts = new CancellationTokenSource();
        _cts = cts;
        var progress = new BlazorProgressHandler(this);
        try
        {
            var request = new TranscribeFileRequest(filePath);
            TranscriptionResult = await _transcriptionService.TranscribeFileAsync(request, progress, cts.Token);
            CurrentState = TranscriptionResult.Success ? AppState.Complete : AppState.Failed;
            if (!TranscriptionResult.Success)
                ErrorMessage = string.Join("; ", TranscriptionResult.Warnings);
        }
        catch (OperationCanceledException)
        {
            System.Diagnostics.Debug.WriteLine("[AppViewModel] Transcription cancelled.");
            GoToReady();
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[AppViewModel] Transcription error: {ex}");
            ErrorMessage = ex.Message;
            CurrentState = AppState.Failed;
        }
        finally
        {
            if (ReferenceEquals(_cts, cts))
            {
                _cts.Dispose();
                _cts = null;
            }
        }
        System.Diagnostics.Debug.WriteLine($"[AppViewModel] TranscribeFileAsync finished. State={CurrentState}");
    }

    /// <summary>
    /// Re-runs transcription for the previously selected file when one is available.
    /// Resets state to Ready first so the start guard is satisfied.
    /// </summary>
    public async Task RetryAsync()
    {
        if (_lastFilePath == null) return;
        var filePath = _lastFilePath;
        GoToReady();
        await TranscribeFileAsync(filePath);
    }

    /// <summary>
    /// Returns the UI to its ready state and clears transient run data.
    /// </summary>
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
