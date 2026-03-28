namespace VoxFlow.Core.Services;

using System.Diagnostics;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;

internal sealed class TranscriptionService : ITranscriptionService
{
    private const double TranscribingStageStartPercent = 30d;
    private const double TranscribingStageEndPercent = 90d;

    private readonly IConfigurationService _configService;
    private readonly IValidationService _validationService;
    private readonly IAudioConversionService _audioConversion;
    private readonly IModelService _modelService;
    private readonly IWavAudioLoader _wavLoader;
    private readonly ILanguageSelectionService _languageSelection;
    private readonly IOutputWriter _outputWriter;

    public TranscriptionService(
        IConfigurationService configService,
        IValidationService validationService,
        IAudioConversionService audioConversion,
        IModelService modelService,
        IWavAudioLoader wavLoader,
        ILanguageSelectionService languageSelection,
        IOutputWriter outputWriter)
    {
        _configService = configService;
        _validationService = validationService;
        _audioConversion = audioConversion;
        _modelService = modelService;
        _wavLoader = wavLoader;
        _languageSelection = languageSelection;
        _outputWriter = outputWriter;
    }

    public async Task<TranscribeFileResult> TranscribeFileAsync(
        TranscribeFileRequest request,
        IProgress<ProgressUpdate>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var stopwatch = Stopwatch.StartNew();
        var warnings = new List<string>();

        // 1. Load config
        var options = await _configService.LoadAsync(request.ConfigurationPath);

        var inputPath = request.InputPath;
        var resultPath = request.ResultFilePath ?? options.ResultFilePath;
        var wavPath = options.WavFilePath;

        // 2. Validate
        progress?.Report(new ProgressUpdate(ProgressStage.Validating, 0, stopwatch.Elapsed, "Validating environment..."));

        if (options.StartupValidation.Enabled)
        {
            var validation = await _validationService.ValidateAsync(options, cancellationToken);
            if (!validation.CanStart)
            {
                return new TranscribeFileResult(
                    false, null, null, 0, 0, stopwatch.Elapsed,
                    validation.Checks.Where(c => c.Status == ValidationCheckStatus.Failed).Select(c => c.Details).ToList(),
                    null);
            }
            if (validation.HasWarnings)
            {
                warnings.AddRange(validation.Checks
                    .Where(c => c.Status == ValidationCheckStatus.Warning)
                    .Select(c => c.Details));
            }
        }

        // 3. Convert audio
        progress?.Report(new ProgressUpdate(ProgressStage.Converting, 10, stopwatch.Elapsed, "Converting audio..."));
        await _audioConversion.ConvertToWavAsync(inputPath, wavPath, options, cancellationToken);

        // 4. Load model
        progress?.Report(new ProgressUpdate(ProgressStage.LoadingModel, 20, stopwatch.Elapsed, "Loading model..."));
        var factory = await _modelService.GetOrCreateFactoryAsync(options, cancellationToken);

        // 5. Load WAV samples
        var audioSamples = await _wavLoader.LoadSamplesAsync(wavPath, options, cancellationToken);

        // 6. Transcribe + select language
        progress?.Report(new ProgressUpdate(
            ProgressStage.Transcribing,
            TranscribingStageStartPercent,
            stopwatch.Elapsed,
            "Transcribing..."));
        var selectionProgress = CreateLanguageSelectionProgressReporter(progress, stopwatch);
        var selectionResult = await _languageSelection.SelectBestCandidateAsync(
            factory, audioSamples, options, selectionProgress, cancellationToken);

        if (selectionResult.Warning != null)
            warnings.Add(selectionResult.Warning);

        // 7. Write output
        progress?.Report(new ProgressUpdate(ProgressStage.Writing, 90, stopwatch.Elapsed, "Writing transcript..."));
        await _outputWriter.WriteAsync(resultPath, selectionResult.AcceptedSegments, cancellationToken);

        stopwatch.Stop();

        // 8. Build preview
        var preview = _outputWriter.BuildOutputText(
            selectionResult.AcceptedSegments.Take(10).ToList());

        progress?.Report(new ProgressUpdate(ProgressStage.Complete, 100, stopwatch.Elapsed, "Complete"));

        return new TranscribeFileResult(
            true,
            $"{selectionResult.Language.DisplayName} ({selectionResult.Language.Code})",
            resultPath,
            selectionResult.AcceptedSegments.Count,
            selectionResult.SkippedSegments.Count,
            stopwatch.Elapsed,
            warnings,
            preview);
    }

    internal static double MapLanguageSelectionPercentToPipelinePercent(double selectionPercent)
    {
        var clamped = Math.Clamp(selectionPercent, 0d, 100d);
        return TranscribingStageStartPercent +
               ((TranscribingStageEndPercent - TranscribingStageStartPercent) * (clamped / 100d));
    }

    private static IProgress<ProgressUpdate>? CreateLanguageSelectionProgressReporter(
        IProgress<ProgressUpdate>? progress,
        Stopwatch stopwatch)
    {
        if (progress is null)
        {
            return null;
        }

        return new Progress<ProgressUpdate>(update =>
        {
            progress.Report(update with
            {
                PercentComplete = MapLanguageSelectionPercentToPipelinePercent(update.PercentComplete),
                Elapsed = stopwatch.Elapsed
            });
        });
    }
}
