using System.ComponentModel;
using System.Linq;
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
        private set
        {
            _validationResult = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(HasBlockingValidationErrors));
            OnPropertyChanged(nameof(BlockingValidationMessage));
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

    public string? BlockingValidationMessage => ValidationResult?.Checks is null
        ? null
        : string.Join(
            "; ",
            ValidationResult.Checks
                .Where(check => check.Status == ValidationCheckStatus.Failed)
                .Select(check => check.Details));

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
        System.Diagnostics.Debug.WriteLine($"[AppViewModel] TranscribeFileAsync started: {filePath}");
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
        catch (OperationCanceledException)
        {
            System.Diagnostics.Debug.WriteLine("[AppViewModel] Transcription cancelled.");
            CurrentState = AppState.Ready;
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[AppViewModel] Transcription error: {ex}");
            ErrorMessage = ex.Message;
            CurrentState = AppState.Failed;
        }
        System.Diagnostics.Debug.WriteLine($"[AppViewModel] TranscribeFileAsync finished. State={CurrentState}");
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
