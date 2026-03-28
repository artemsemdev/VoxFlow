namespace VoxFlow.Core.Services;

using System.Diagnostics;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;

internal sealed class BatchTranscriptionService : IBatchTranscriptionService
{
    private const double BatchProcessingStartPercent = 10d;
    private const double BatchProcessingEndPercent = 90d;
    private const double FileTranscribingStartPercent = 10d;
    private const double FileTranscribingEndPercent = 90d;

    private readonly IConfigurationService _configService;
    private readonly IValidationService _validationService;
    private readonly IFileDiscoveryService _fileDiscovery;
    private readonly IAudioConversionService _audioConversion;
    private readonly IModelService _modelService;
    private readonly IWavAudioLoader _wavLoader;
    private readonly ILanguageSelectionService _languageSelection;
    private readonly IOutputWriter _outputWriter;
    private readonly IBatchSummaryWriter _summaryWriter;

    public BatchTranscriptionService(
        IConfigurationService configService,
        IValidationService validationService,
        IFileDiscoveryService fileDiscovery,
        IAudioConversionService audioConversion,
        IModelService modelService,
        IWavAudioLoader wavLoader,
        ILanguageSelectionService languageSelection,
        IOutputWriter outputWriter,
        IBatchSummaryWriter summaryWriter)
    {
        ArgumentNullException.ThrowIfNull(configService);
        ArgumentNullException.ThrowIfNull(validationService);
        ArgumentNullException.ThrowIfNull(fileDiscovery);
        ArgumentNullException.ThrowIfNull(audioConversion);
        ArgumentNullException.ThrowIfNull(modelService);
        ArgumentNullException.ThrowIfNull(wavLoader);
        ArgumentNullException.ThrowIfNull(languageSelection);
        ArgumentNullException.ThrowIfNull(outputWriter);
        ArgumentNullException.ThrowIfNull(summaryWriter);

        _configService = configService;
        _validationService = validationService;
        _fileDiscovery = fileDiscovery;
        _audioConversion = audioConversion;
        _modelService = modelService;
        _wavLoader = wavLoader;
        _languageSelection = languageSelection;
        _outputWriter = outputWriter;
        _summaryWriter = summaryWriter;
    }

    public async Task<BatchTranscribeResult> TranscribeBatchAsync(
        BatchTranscribeRequest request,
        IProgress<ProgressUpdate>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        var totalStopwatch = Stopwatch.StartNew();
        var options = await _configService.LoadAsync(request.ConfigurationPath);
        var batchOptions = options.Batch;

        // 1. Validate
        if (options.StartupValidation.Enabled)
        {
            var validation = await _validationService.ValidateAsync(options, cancellationToken);
            if (!validation.CanStart)
            {
                // Abort before discovery so startup failures do not get mixed into per-file batch results.
                return new BatchTranscribeResult(0, 0, 0, 0, null, totalStopwatch.Elapsed, new List<BatchFileResult>());
            }
        }

        // 2. Create factory once (ADR-010, ADR-011)
        progress?.Report(new ProgressUpdate(ProgressStage.LoadingModel, 5, totalStopwatch.Elapsed, "Loading model..."));
        var factory = await _modelService.GetOrCreateFactoryAsync(options, cancellationToken);

        // 3. Discover files
        var discoveredFiles = _fileDiscovery.DiscoverInputFiles(batchOptions, request.MaxFiles);
        var results = new List<BatchFileResult>(discoveredFiles.Count);

        // 4. Process each file
        for (var i = 0; i < discoveredFiles.Count; i++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var file = discoveredFiles[i];

            if (file.Status == DiscoveryStatus.Skipped)
            {
                results.Add(new BatchFileResult(
                    file.InputPath, file.OutputPath, "Skipped",
                    file.SkipReason, TimeSpan.Zero, null));
                continue;
            }

            ReportBatchFileProgress(
                progress,
                totalStopwatch,
                i,
                discoveredFiles.Count,
                file.InputPath,
                ProgressStage.Converting,
                0,
                "Converting audio...");

            var fileStopwatch = Stopwatch.StartNew();
            try
            {
                await _audioConversion.ConvertToWavAsync(file.InputPath, file.TempWavPath, options, cancellationToken);
                var samples = await _wavLoader.LoadSamplesAsync(file.TempWavPath, options, cancellationToken);
                var fileProgress = CreateBatchFileProgressReporter(
                    progress,
                    totalStopwatch,
                    i,
                    discoveredFiles.Count,
                    file.InputPath);
                var selection = await _languageSelection.SelectBestCandidateAsync(
                    factory,
                    samples,
                    options,
                    fileProgress,
                    cancellationToken);
                ReportBatchFileProgress(
                    progress,
                    totalStopwatch,
                    i,
                    discoveredFiles.Count,
                    file.InputPath,
                    ProgressStage.Writing,
                    95,
                    "Writing transcript...");
                await _outputWriter.WriteAsync(file.OutputPath, selection.AcceptedSegments, cancellationToken);

                fileStopwatch.Stop();
                results.Add(new BatchFileResult(
                    file.InputPath, file.OutputPath, "Success",
                    null, fileStopwatch.Elapsed,
                    $"{selection.Language.DisplayName} ({selection.Language.Code})"));
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                fileStopwatch.Stop();
                results.Add(new BatchFileResult(
                    file.InputPath, file.OutputPath, "Failed",
                    ex.Message, fileStopwatch.Elapsed, null));

                if (batchOptions.StopOnFirstError) break;
            }
            finally
            {
                CleanupTempWav(file.TempWavPath, batchOptions.KeepIntermediateFiles);
            }
        }

        // The summary writer already speaks the shared file-processing model, so project the batch-specific results once here.
        var fileResults = results.Select(r => new FileProcessingResult(
            r.InputPath, r.OutputPath,
            r.Status switch { "Success" => FileProcessingStatus.Success, "Failed" => FileProcessingStatus.Failed, _ => FileProcessingStatus.Skipped },
            r.ErrorMessage, r.Duration, r.DetectedLanguage)).ToList();
        await _summaryWriter.WriteAsync(batchOptions.SummaryFilePath, fileResults, cancellationToken);

        totalStopwatch.Stop();
        var succeeded = results.Count(r => r.Status == "Success");
        var failed = results.Count(r => r.Status == "Failed");
        var skipped = results.Count(r => r.Status == "Skipped");

        progress?.Report(new ProgressUpdate(ProgressStage.Complete, 100, totalStopwatch.Elapsed,
            $"Batch complete: {succeeded} succeeded, {failed} failed, {skipped} skipped"));

        return new BatchTranscribeResult(
            results.Count, succeeded, failed, skipped,
            batchOptions.SummaryFilePath, totalStopwatch.Elapsed, results);
    }

    internal static double MapBatchFilePercent(int fileIndex, int totalFiles, double filePercent)
    {
        var normalizedCount = Math.Max(totalFiles, 1);
        var normalizedIndex = Math.Clamp(fileIndex, 0, normalizedCount - 1);
        var normalizedPercent = Math.Clamp(filePercent, 0d, 100d) / 100d;

        return BatchProcessingStartPercent +
               (((normalizedIndex + normalizedPercent) / normalizedCount) *
                (BatchProcessingEndPercent - BatchProcessingStartPercent));
    }

    private static IProgress<ProgressUpdate>? CreateBatchFileProgressReporter(
        IProgress<ProgressUpdate>? progress,
        Stopwatch totalStopwatch,
        int fileIndex,
        int totalFiles,
        string inputPath)
    {
        if (progress is null)
        {
            return null;
        }

        return new Progress<ProgressUpdate>(update =>
        {
            var filePercent = FileTranscribingStartPercent +
                              ((FileTranscribingEndPercent - FileTranscribingStartPercent) *
                               (Math.Clamp(update.PercentComplete, 0d, 100d) / 100d));

            progress.Report(update with
            {
                PercentComplete = MapBatchFilePercent(fileIndex, totalFiles, filePercent),
                Elapsed = totalStopwatch.Elapsed,
                Message = FormatBatchFileMessage(fileIndex, totalFiles, inputPath, update.Message),
                BatchFileIndex = fileIndex + 1,
                BatchFileTotal = totalFiles
            });
        });
    }

    private static void ReportBatchFileProgress(
        IProgress<ProgressUpdate>? progress,
        Stopwatch totalStopwatch,
        int fileIndex,
        int totalFiles,
        string inputPath,
        ProgressStage stage,
        double filePercent,
        string message,
        string? currentLanguage = null)
    {
        progress?.Report(new ProgressUpdate(
            stage,
            MapBatchFilePercent(fileIndex, totalFiles, filePercent),
            totalStopwatch.Elapsed,
            FormatBatchFileMessage(fileIndex, totalFiles, inputPath, message),
            currentLanguage,
            fileIndex + 1,
            totalFiles));
    }

    private static string FormatBatchFileMessage(
        int fileIndex,
        int totalFiles,
        string inputPath,
        string? message)
    {
        var prefix = $"[{fileIndex + 1}/{totalFiles}] {Path.GetFileName(inputPath)}";
        return string.IsNullOrWhiteSpace(message)
            ? prefix
            : $"{prefix} - {message}";
    }

    private static void CleanupTempWav(string wavPath, bool keepIntermediateFiles)
    {
        if (keepIntermediateFiles) return;
        try
        {
            if (File.Exists(wavPath))
            {
                File.Delete(wavPath);
            }
        }
        catch (IOException)
        {
            // Temp WAV cleanup is best-effort because a failed delete should not hide the transcription result.
        }
        catch (UnauthorizedAccessException)
        {
            // Temp WAV cleanup is best-effort because a failed delete should not hide the transcription result.
        }
    }
}
