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
    private readonly ISpeakerEnrichmentService _speakerEnrichment;
    private readonly IVoxflowTranscriptArtifactWriter _artifactWriter;

    public BatchTranscriptionService(
        IConfigurationService configService,
        IValidationService validationService,
        IFileDiscoveryService fileDiscovery,
        IAudioConversionService audioConversion,
        IModelService modelService,
        IWavAudioLoader wavLoader,
        ILanguageSelectionService languageSelection,
        IOutputWriter outputWriter,
        IBatchSummaryWriter summaryWriter,
        ISpeakerEnrichmentService speakerEnrichment,
        IVoxflowTranscriptArtifactWriter artifactWriter)
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
        ArgumentNullException.ThrowIfNull(speakerEnrichment);
        ArgumentNullException.ThrowIfNull(artifactWriter);

        _configService = configService;
        _validationService = validationService;
        _fileDiscovery = fileDiscovery;
        _audioConversion = audioConversion;
        _modelService = modelService;
        _wavLoader = wavLoader;
        _languageSelection = languageSelection;
        _outputWriter = outputWriter;
        _summaryWriter = summaryWriter;
        _speakerEnrichment = speakerEnrichment;
        _artifactWriter = artifactWriter;
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
        var outputExtension = options.ResultFormat.ToFileExtension();
        var discoveredFiles = _fileDiscovery.DiscoverInputFiles(batchOptions, request.MaxFiles, outputExtension);
        var results = new List<BatchFileResult>(discoveredFiles.Count);

        // Host override wins over config default — matches TranscriptionService single-file behavior.
        var speakerLabelingEnabled = request.EnableSpeakers ?? options.SpeakerLabeling.Enabled;

        // 4. Process each file
        var cancelled = false;
        var remainingStartIndex = discoveredFiles.Count;
        for (var i = 0; i < discoveredFiles.Count; i++)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                // Cancellation between files: stop the loop and let the post-loop
                // block tag every remaining file as Cancelled in the result. This
                // gives the caller a partial-progress BatchTranscribeResult instead
                // of a bare OperationCanceledException with no visibility into
                // which files completed.
                cancelled = true;
                remainingStartIndex = i;
                break;
            }
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

                // Speaker enrichment (optional) — matches TranscriptionService single-file path.
                TranscriptDocument? speakerTranscript = null;
                var fileWarnings = new List<string>();
                if (speakerLabelingEnabled)
                {
                    try
                    {
                        var metadata = new TranscriptMetadata(
                            SchemaVersion: 1,
                            DiarizationModel: options.SpeakerLabeling.ModelId,
                            SidecarVersion: 1);
                        var enrichmentResult = await _speakerEnrichment.EnrichAsync(
                            file.TempWavPath,
                            selection.AcceptedSegments,
                            metadata,
                            options.SpeakerLabeling,
                            fileProgress,
                            cancellationToken);
                        speakerTranscript = enrichmentResult.Document;
                        if (enrichmentResult.Warnings.Count > 0)
                        {
                            fileWarnings.AddRange(enrichmentResult.Warnings);
                        }
                    }
                    catch (OperationCanceledException)
                    {
                        throw;
                    }
                    catch (Exception ex)
                    {
                        fileWarnings.Add($"speaker-labeling: internal error: {ex.Message}");
                    }
                }

                ReportBatchFileProgress(
                    progress,
                    totalStopwatch,
                    i,
                    discoveredFiles.Count,
                    file.InputPath,
                    ProgressStage.Writing,
                    95,
                    "Writing transcript...");

                var detectedLanguage = $"{selection.Language.DisplayName} ({selection.Language.Code})";
                var outputContext = new TranscriptOutputContext(
                    Format: options.ResultFormat,
                    DetectedLanguage: detectedLanguage,
                    AcceptedSegmentCount: selection.AcceptedSegments.Count,
                    SkippedSegmentCount: selection.SkippedSegments.Count,
                    Warnings: fileWarnings,
                    SpeakerTranscript: speakerTranscript);

                await _outputWriter.WriteAsync(file.OutputPath, selection.AcceptedSegments, outputContext, cancellationToken);

                if (speakerTranscript is not null)
                {
                    await _artifactWriter.WriteAsync(file.OutputPath, speakerTranscript, cancellationToken);
                }

                fileStopwatch.Stop();
                results.Add(new BatchFileResult(
                    file.InputPath, file.OutputPath, "Success",
                    null, fileStopwatch.Elapsed,
                    detectedLanguage));
            }
            catch (OperationCanceledException)
            {
                // Mid-file cancellation: record this file as Cancelled and exit the
                // loop. The temp-WAV cleanup in `finally` still runs so the partially
                // written WAV does not outlive the run.
                fileStopwatch.Stop();
                results.Add(new BatchFileResult(
                    file.InputPath, file.OutputPath, "Cancelled",
                    "Batch cancelled during transcription.", fileStopwatch.Elapsed, null));
                cancelled = true;
                remainingStartIndex = i + 1;
                break;
            }
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

        // Mark every file that was discovered but never reached as Cancelled. This
        // closes the gap left by the cancellation break above so caller-visible
        // counts always satisfy succeeded + failed + skipped == TotalFiles.
        for (var j = remainingStartIndex; j < discoveredFiles.Count; j++)
        {
            var remaining = discoveredFiles[j];
            results.Add(new BatchFileResult(
                remaining.InputPath, remaining.OutputPath, "Cancelled",
                "Batch cancelled before this file started.", TimeSpan.Zero, null));
        }

        // The summary writer already speaks the shared file-processing model, so project the batch-specific results once here.
        // Cancelled buckets under Skipped for the summary file and for the integer
        // counters: the existing FileProcessingStatus enum has Success/Failed/Skipped
        // and the BatchTranscribeResult contract is positional, so adding a Cancelled
        // counter would be a breaking record shape. The string Status preserves the
        // distinction for callers that need it (Results[*].Status == "Cancelled").
        var fileResults = results.Select(r => new FileProcessingResult(
            r.InputPath, r.OutputPath,
            r.Status switch { "Success" => FileProcessingStatus.Success, "Failed" => FileProcessingStatus.Failed, _ => FileProcessingStatus.Skipped },
            r.ErrorMessage, r.Duration, r.DetectedLanguage)).ToList();
        // The summary write itself uses the original (un-linked) cancellation token
        // so an already-cancelled batch can still flush its partial summary to disk.
        // Without this, a cancelled run would also lose its summary file.
        await _summaryWriter.WriteAsync(batchOptions.SummaryFilePath, fileResults, CancellationToken.None);

        totalStopwatch.Stop();
        var succeeded = results.Count(r => r.Status == "Success");
        var failed = results.Count(r => r.Status == "Failed");
        var skipped = results.Count(r => r.Status == "Skipped" || r.Status == "Cancelled");
        var cancelledCount = results.Count(r => r.Status == "Cancelled");

        var completionMessage = cancelled
            ? $"Batch cancelled: {succeeded} succeeded, {failed} failed, {skipped - cancelledCount} skipped, {cancelledCount} cancelled"
            : $"Batch complete: {succeeded} succeeded, {failed} failed, {skipped} skipped";
        progress?.Report(new ProgressUpdate(ProgressStage.Complete, 100, totalStopwatch.Elapsed, completionMessage));

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
