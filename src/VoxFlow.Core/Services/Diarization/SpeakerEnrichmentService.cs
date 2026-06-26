using System.Diagnostics;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services.Python;

namespace VoxFlow.Core.Services.Diarization;

/// <inheritdoc />
public sealed class SpeakerEnrichmentService : ISpeakerEnrichmentService
{
    private readonly IPythonRuntime _runtime;
    private readonly IDiarizationSidecar _sidecar;
    private readonly ISpeakerMergeService _mergeService;
    private readonly IManagedVenvBootstrapper _bootstrapper;
    private readonly ILogger<SpeakerEnrichmentService> _logger;

    public SpeakerEnrichmentService(
        IPythonRuntime runtime,
        IDiarizationSidecar sidecar,
        ISpeakerMergeService mergeService,
        IManagedVenvBootstrapper bootstrapper,
        ILogger<SpeakerEnrichmentService>? logger = null)
    {
        ArgumentNullException.ThrowIfNull(runtime);
        ArgumentNullException.ThrowIfNull(sidecar);
        ArgumentNullException.ThrowIfNull(mergeService);
        ArgumentNullException.ThrowIfNull(bootstrapper);
        _runtime = runtime;
        _sidecar = sidecar;
        _mergeService = mergeService;
        _bootstrapper = bootstrapper;
        _logger = logger ?? NullLogger<SpeakerEnrichmentService>.Instance;
    }

    public async Task<SpeakerEnrichmentResult> EnrichAsync(
        string wavPath,
        IReadOnlyList<FilteredSegment> segments,
        TranscriptMetadata metadata,
        SpeakerLabelingOptions options,
        IProgress<ProgressUpdate>? progress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(wavPath);
        ArgumentNullException.ThrowIfNull(segments);
        ArgumentNullException.ThrowIfNull(metadata);
        ArgumentNullException.ThrowIfNull(options);

        if (!options.Enabled)
        {
            return SpeakerEnrichmentResult.Empty;
        }

        var runtimeBootstrapped = false;
        var status = await _runtime.GetStatusAsync(cancellationToken).ConfigureAwait(false);
        if (!status.IsReady && status.CanBootstrap)
        {
            _logger.LogInformation(
                "Bootstrapping speaker-labeling runtime for mode {RuntimeMode}.",
                options.RuntimeMode);
            await _bootstrapper.BootstrapAsync(progress: null, cancellationToken).ConfigureAwait(false);
            runtimeBootstrapped = true;
            status = await _runtime.GetStatusAsync(cancellationToken).ConfigureAwait(false);
        }

        if (!status.IsReady)
        {
            var diagnostic = SpeakerLabelingDiagnostics.FromRuntimeStatus(status);
            LogDiagnostic(diagnostic);
            return new SpeakerEnrichmentResult(
                Document: null,
                Warnings: new[] { diagnostic.ToWarningString() },
                RuntimeBootstrapped: runtimeBootstrapped);
        }

        using var timeoutCts = new CancellationTokenSource(TimeSpan.FromSeconds(options.TimeoutSeconds));
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
        var stopwatch = Stopwatch.StartNew();

        // Emit an initial Diarizing update at the lower bound of the band
        // BEFORE calling the sidecar. Python boot + pyannote import +
        // Pipeline.from_pretrained can take 5-30s during which the sidecar
        // cannot emit NDJSON (stdout/stderr are captured into a StringIO to
        // keep library chatter out of the protocol stream), so the CLI
        // otherwise stays frozen on "Transcribing 90%" for the whole gap.
        // Anchoring at 90% also avoids the old [85, 95] band jumping the bar
        // backwards from the 90% end of the Transcribing band.
        progress?.Report(new ProgressUpdate(
            Stage: ProgressStage.Diarizing,
            PercentComplete: 90.0,
            Elapsed: stopwatch.Elapsed,
            Message: "starting"));

        // Synchronous IProgress<T> adapter: Progress<T> would queue to
        // SynchronizationContext/ThreadPool and lose FIFO ordering between
        // reports, which matters for downstream progress bar rendering.
        var sidecarProgress = progress is null
            ? null
            : new DelegateProgress<SpeakerLabelingProgress>(update =>
            {
                var fraction = update.Fraction ?? 0.0;
                if (fraction < 0.0) fraction = 0.0;
                else if (fraction > 1.0) fraction = 1.0;
                var percent = 90.0 + (fraction * 5.0); // map [0,1] into [90,95]
                progress.Report(new ProgressUpdate(
                    Stage: ProgressStage.Diarizing,
                    PercentComplete: percent,
                    Elapsed: stopwatch.Elapsed,
                    Message: update.Stage));
            });

        DiarizationResult diarization;
        try
        {
            diarization = await _sidecar
                .DiarizeAsync(new DiarizationRequest(wavPath), sidecarProgress, linkedCts.Token)
                .ConfigureAwait(false);
        }
        catch (DiarizationSidecarException ex)
        {
            var diagnostic = SpeakerLabelingDiagnostics.FromSidecar(ex.Reason, ex.Message);
            _logger.LogWarning(ex, "Speaker-labeling sidecar failed with reason {Reason}.", ex.Reason);
            return new SpeakerEnrichmentResult(
                Document: null,
                Warnings: new[] { diagnostic.ToWarningString() },
                RuntimeBootstrapped: runtimeBootstrapped);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && timeoutCts.IsCancellationRequested)
        {
            var diagnostic = SpeakerLabelingDiagnostics.Timeout(options.TimeoutSeconds);
            LogDiagnostic(diagnostic);
            return new SpeakerEnrichmentResult(
                Document: null,
                Warnings: new[] { diagnostic.ToWarningString() },
                RuntimeBootstrapped: runtimeBootstrapped);
        }

        var document = _mergeService.Merge(segments, diarization, metadata);
        var warnings = document.Speakers.Count == 0
            ? new[] { "speaker-labeling: diarization returned zero speakers" }
            : Array.Empty<string>();
        if (warnings.Length > 0)
        {
            _logger.LogWarning("Speaker-labeling diarization returned zero speakers.");
        }

        return new SpeakerEnrichmentResult(document, warnings, runtimeBootstrapped);
    }

    private void LogDiagnostic(SpeakerLabelingDiagnostic diagnostic)
    {
        // The user-facing summary/remediation reach callers via the warning; the
        // raw technical detail stays in the log for diagnosability.
        _logger.LogWarning(
            "Speaker-labeling diagnostic {Code}: {Summary} (detail: {TechnicalDetail})",
            diagnostic.CodeString,
            diagnostic.Summary,
            diagnostic.TechnicalDetail ?? "(none)");
    }

    private sealed class DelegateProgress<T> : IProgress<T>
    {
        private readonly Action<T> _handler;
        public DelegateProgress(Action<T> handler) => _handler = handler;
        public void Report(T value) => _handler(value);
    }
}
