namespace VoxFlow.Core.Services;

using System.Diagnostics;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;

internal sealed class BatchTranscriptionService : IBatchTranscriptionService
{
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
        var totalStopwatch = Stopwatch.StartNew();
        var options = await _configService.LoadAsync(request.ConfigurationPath);
        var batchOptions = options.Batch;

        // 1. Validate
        if (options.StartupValidation.Enabled)
        {
            var validation = await _validationService.ValidateAsync(options, cancellationToken);
            if (!validation.CanStart)
            {
                return new BatchTranscribeResult(0, 0, 0, 0, null, totalStopwatch.Elapsed, new List<BatchFileResult>());
            }
        }

        // 2. Create factory once (ADR-010, ADR-011)
        progress?.Report(new ProgressUpdate(ProgressStage.LoadingModel, 5, totalStopwatch.Elapsed, "Loading model..."));
        var factory = await _modelService.GetOrCreateFactoryAsync(options, cancellationToken);

        // 3. Discover files
        var discoveredFiles = _fileDiscovery.DiscoverInputFiles(batchOptions);
        var results = new List<BatchFileResult>(discoveredFiles.Count);

        // 4. Process each file
        for (var i = 0; i < discoveredFiles.Count; i++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var file = discoveredFiles[i];
            var pct = (int)(10 + (80.0 * i / discoveredFiles.Count));

            if (file.Status == DiscoveryStatus.Skipped)
            {
                results.Add(new BatchFileResult(
                    file.InputPath, file.OutputPath, "Skipped",
                    file.SkipReason, TimeSpan.Zero, null));
                continue;
            }

            progress?.Report(new ProgressUpdate(
                ProgressStage.Transcribing, pct, totalStopwatch.Elapsed,
                $"[{i + 1}/{discoveredFiles.Count}] {Path.GetFileName(file.InputPath)}"));

            var fileStopwatch = Stopwatch.StartNew();
            try
            {
                await _audioConversion.ConvertToWavAsync(file.InputPath, file.TempWavPath, options, cancellationToken);
                var samples = await _wavLoader.LoadSamplesAsync(file.TempWavPath, options, cancellationToken);
                var selection = await _languageSelection.SelectBestCandidateAsync(factory, samples, options, null, cancellationToken);
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

        // 5. Write summary — convert BatchFileResult → FileProcessingResult for summary writer
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

    private static void CleanupTempWav(string wavPath, bool keepIntermediateFiles)
    {
        if (keepIntermediateFiles) return;
        try { if (File.Exists(wavPath)) File.Delete(wavPath); }
        catch { /* best-effort */ }
    }
}
