namespace VoxFlow.Core.Services;

using System.Diagnostics;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
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
    private readonly ISpeakerEnrichmentService _speakerEnrichment;
    private readonly IVoxflowTranscriptArtifactWriter _artifactWriter;
    private readonly ILogger<TranscriptionService> _logger;

    public TranscriptionService(
        IConfigurationService configService,
        IValidationService validationService,
        IAudioConversionService audioConversion,
        IModelService modelService,
        IWavAudioLoader wavLoader,
        ILanguageSelectionService languageSelection,
        IOutputWriter outputWriter,
        ISpeakerEnrichmentService speakerEnrichment,
        IVoxflowTranscriptArtifactWriter artifactWriter,
        ILogger<TranscriptionService>? logger = null)
    {
        _configService = configService;
        _validationService = validationService;
        _audioConversion = audioConversion;
        _modelService = modelService;
        _wavLoader = wavLoader;
        _languageSelection = languageSelection;
        _outputWriter = outputWriter;
        _speakerEnrichment = speakerEnrichment;
        _artifactWriter = artifactWriter;
        _logger = logger ?? NullLogger<TranscriptionService>.Instance;
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

        // Normalize the result path extension to match the configured format.
        resultPath = ResultFormatExtensions.NormalizeOutputPath(resultPath, options.ResultFormat);

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

        // 7. Speaker enrichment (optional)
        TranscriptDocument? speakerTranscript = null;
        IReadOnlyList<string> enrichmentWarnings = Array.Empty<string>();
        if (ComputeEffectiveSpeakerFlag(request, options))
        {
            try
            {
                var metadata = new TranscriptMetadata(
                    SchemaVersion: 1,
                    DiarizationModel: options.SpeakerLabeling.ModelId,
                    SidecarVersion: 1);
                var enrichmentResult = await _speakerEnrichment.EnrichAsync(
                    wavPath,
                    selectionResult.AcceptedSegments,
                    metadata,
                    options.SpeakerLabeling,
                    progress,
                    cancellationToken);
                speakerTranscript = enrichmentResult.Document;
                enrichmentWarnings = enrichmentResult.Warnings;
                if (enrichmentResult.Warnings.Count > 0)
                {
                    warnings.AddRange(enrichmentResult.Warnings);
                }
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                _logger.LogError(
                    ex,
                    "Speaker enrichment failed for {WavPath}; falling back to plain transcript.",
                    wavPath);
                var warning = $"speaker-labeling: internal error: {ex.Message}";
                enrichmentWarnings = new[] { warning };
                warnings.Add(warning);
            }
        }

        // 8. Write output
        progress?.Report(new ProgressUpdate(ProgressStage.Writing, 95, stopwatch.Elapsed, "Writing transcript..."));

        var detectedLanguage = $"{selectionResult.Language.DisplayName} ({selectionResult.Language.Code})";
        var outputContext = new TranscriptOutputContext(
            Format: options.ResultFormat,
            DetectedLanguage: detectedLanguage,
            AcceptedSegmentCount: selectionResult.AcceptedSegments.Count,
            SkippedSegmentCount: selectionResult.SkippedSegments.Count,
            Warnings: warnings,
            SpeakerTranscript: speakerTranscript);

        await _outputWriter.WriteAsync(resultPath, selectionResult.AcceptedSegments, outputContext, cancellationToken);

        if (speakerTranscript is not null)
        {
            await _artifactWriter.WriteAsync(resultPath, speakerTranscript, cancellationToken);
        }

        stopwatch.Stop();

        // 9. Build preview (always as TXT for display)
        var previewContext = new TranscriptOutputContext(Format: ResultFormat.Txt);
        var preview = _outputWriter.BuildOutputText(
            selectionResult.AcceptedSegments.Take(10).ToList(), previewContext);

        progress?.Report(new ProgressUpdate(ProgressStage.Complete, 100, stopwatch.Elapsed, "Complete"));

        return new TranscribeFileResult(
            true,
            detectedLanguage,
            resultPath,
            selectionResult.AcceptedSegments.Count,
            selectionResult.SkippedSegments.Count,
            stopwatch.Elapsed,
            warnings,
            preview,
            SpeakerTranscript: speakerTranscript,
            EnrichmentWarnings: enrichmentWarnings);
    }

    internal static double MapLanguageSelectionPercentToPipelinePercent(double selectionPercent)
    {
        var clamped = Math.Clamp(selectionPercent, 0d, 100d);
        return TranscribingStageStartPercent +
               ((TranscribingStageEndPercent - TranscribingStageStartPercent) * (clamped / 100d));
    }

    private static bool ComputeEffectiveSpeakerFlag(TranscribeFileRequest request, TranscriptionOptions options)
        => request.EnableSpeakers ?? options.SpeakerLabeling.Enabled;

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
