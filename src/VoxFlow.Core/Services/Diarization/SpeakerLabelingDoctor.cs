using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services.Python;

namespace VoxFlow.Core.Services.Diarization;

/// <summary>Runs the <c>doctor speakers</c> readiness checks.</summary>
public interface ISpeakerLabelingDoctor
{
    Task<SpeakerLabelingHealthReport> CheckAsync(CancellationToken cancellationToken);
}

/// <summary>
/// Gathers readiness signals (config, Python runtime preflight, model cache,
/// Hugging Face token, runtime stamp) and hands them to
/// <see cref="SpeakerLabelingHealthEvaluator"/>. Deliberately does not load the
/// diarization model or run the interpreter — those checks are reported as
/// skipped until the smoke-test work lands.
/// </summary>
public sealed class SpeakerLabelingDoctor : ISpeakerLabelingDoctor
{
    private readonly IConfigurationService _configuration;
    private readonly ISpeakerLabelingPreflight _preflight;
    private readonly IRuntimeStampStore _stampStore;
    private readonly string _requirementsFilePath;
    private readonly string _sidecarScriptPath;
    private readonly Func<string, string?> _environmentLookup;

    public SpeakerLabelingDoctor(
        IConfigurationService configuration,
        ISpeakerLabelingPreflight preflight,
        IRuntimeStampStore stampStore,
        string requirementsFilePath,
        string sidecarScriptPath,
        Func<string, string?>? environmentLookup = null)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ArgumentNullException.ThrowIfNull(preflight);
        ArgumentNullException.ThrowIfNull(stampStore);
        _configuration = configuration;
        _preflight = preflight;
        _stampStore = stampStore;
        _requirementsFilePath = requirementsFilePath;
        _sidecarScriptPath = sidecarScriptPath;
        _environmentLookup = environmentLookup ?? Environment.GetEnvironmentVariable;
    }

    public async Task<SpeakerLabelingHealthReport> CheckAsync(CancellationToken cancellationToken)
    {
        SpeakerLabelingOptions options;
        try
        {
            var loaded = await _configuration.LoadAsync().ConfigureAwait(false);
            options = loaded.SpeakerLabeling;
        }
        catch (Exception ex)
        {
            // Config could not be read; nothing else can be trusted, so stop here.
            return new SpeakerLabelingHealthReport(
                IsReady: false,
                Checks: new[] { new HealthCheck("configuration", HealthCheckStatus.Fail, ex.Message) },
                NextAction: "Fix the configuration error, then re-run `voxflow doctor speakers`.");
        }

        var runtimeStatus = await _preflight.GetRuntimeStatusAsync(options, cancellationToken).ConfigureAwait(false);
        var modelCached = _preflight.IsModelCached(options.ModelId);
        var tokenPresent =
            !string.IsNullOrWhiteSpace(_environmentLookup("HUGGING_FACE_HUB_TOKEN")) ||
            !string.IsNullOrWhiteSpace(_environmentLookup("HF_TOKEN"));

        // The runtime stamp only describes the managed venv; other modes have no stamp.
        SpeakerLabelingRuntimeState? stampState = options.RuntimeMode == PythonRuntimeMode.ManagedVenv
            ? EvaluateStamp()
            : null;

        var report = SpeakerLabelingHealthEvaluator.Evaluate(options, runtimeStatus, modelCached, tokenPresent, stampState);

        // Reaching here means config loaded; record it as the first check.
        var checks = new List<HealthCheck> { new("configuration", HealthCheckStatus.Ok, "loaded") };
        checks.AddRange(report.Checks);
        return report with { Checks = checks };
    }

    private SpeakerLabelingRuntimeState EvaluateStamp()
    {
        var read = _stampStore.Read();
        if (read.Status != RuntimeStampReadStatus.Ok)
        {
            // Missing -> SetupNeeded; Corrupt -> RepairNeeded (hashes are irrelevant).
            return RuntimeStampEvaluator.Evaluate(read, expectedRequirementsHash: null, expectedSidecarHash: null);
        }

        return RuntimeStampEvaluator.Evaluate(read, TryHash(_requirementsFilePath), TryHash(_sidecarScriptPath));
    }

    private static string? TryHash(string path)
    {
        try
        {
            return RuntimeFingerprint.HashFile(path);
        }
        catch (Exception ex) when (ex is System.IO.IOException or UnauthorizedAccessException or ArgumentException)
        {
            return null;
        }
    }
}
