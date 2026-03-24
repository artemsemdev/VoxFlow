using System.ComponentModel;
using System.Runtime.CompilerServices;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;

namespace VoxFlow.Desktop.ViewModels;

public class AppViewModel : INotifyPropertyChanged
{
    private readonly ITranscriptionService _transcriptionService;
    private readonly IValidationService _validationService;
    private readonly IConfigurationService _configService;
    private readonly IModelService _modelService;

    private AppState _currentState = AppState.NotReady;
    private ValidationResult? _validationResult;
    private TranscribeFileResult? _transcriptionResult;
    private ProgressUpdate? _currentProgress;
    private string? _errorMessage;
    private string? _lastFilePath;
    private bool _isDownloadingModel;
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
        _modelService = modelService;
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

    public async Task InitializeAsync()
    {
        var options = await _configService.LoadAsync();
        var result = await _validationService.ValidateAsync(options);
        ValidationResult = result;
        CurrentState = result.CanStart ? AppState.Ready : AppState.NotReady;
    }

    public async Task TranscribeFileAsync(string filePath)
    {
        _lastFilePath = filePath;
        CurrentState = AppState.Running;
        ErrorMessage = null;
        _cts = new CancellationTokenSource();
        var progress = new Progress<ProgressUpdate>(update => CurrentProgress = update);
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

    public async Task RevalidateAsync() => await InitializeAsync();

    public bool IsDownloadingModel
    {
        get => _isDownloadingModel;
        private set { _isDownloadingModel = value; OnPropertyChanged(); }
    }

    public async Task DownloadModelAsync()
    {
        IsDownloadingModel = true;
        try
        {
            var options = await _configService.LoadAsync();
            await _modelService.GetOrCreateFactoryAsync(options);
            await RevalidateAsync();
        }
        catch (Exception ex) { ErrorMessage = $"Model download failed: {ex.Message}"; }
        finally { IsDownloadingModel = false; }
    }

    public void CancelTranscription() => _cts?.Cancel();

    public event PropertyChangedEventHandler? PropertyChanged;
    public void NotifyStateChanged() => OnPropertyChanged(string.Empty);
    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
