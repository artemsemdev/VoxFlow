using System.Collections.Generic;
using System.Linq;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services.Python;

namespace VoxFlow.Core.Services.Diarization;

/// <summary>
/// Turns already-gathered readiness signals into a <see cref="SpeakerLabelingHealthReport"/>.
/// Pure and deterministic so the decision logic is unit-testable without a real
/// Python runtime; the orchestrating doctor does the I/O. Checks that need the
/// live runtime (dependency imports, sidecar smoke) are reported as
/// <see cref="HealthCheckStatus.Skip"/> here and produced by the smoke-test work.
/// </summary>
public static class SpeakerLabelingHealthEvaluator
{
    public static SpeakerLabelingHealthReport Evaluate(
        SpeakerLabelingOptions options,
        PythonRuntimeStatus runtimeStatus,
        bool modelCached,
        bool tokenPresent,
        SpeakerLabelingRuntimeState? stampState)
    {
        System.ArgumentNullException.ThrowIfNull(options);
        System.ArgumentNullException.ThrowIfNull(runtimeStatus);

        var checks = new List<HealthCheck>();
        string? nextAction = null;

        void Add(HealthCheck check, string? remediation = null)
        {
            checks.Add(check);
            if (check.Status == HealthCheckStatus.Fail && nextAction is null)
            {
                nextAction = remediation;
            }
        }

        Add(new HealthCheck("runtime mode", HealthCheckStatus.Ok, options.RuntimeMode.ToString()));

        if (runtimeStatus.IsReady)
        {
            Add(new HealthCheck("python runtime", HealthCheckStatus.Ok,
                $"{runtimeStatus.Version} at {runtimeStatus.InterpreterPath}"));
        }
        else
        {
            var diag = SpeakerLabelingDiagnostics.FromRuntimeStatus(runtimeStatus);
            Add(new HealthCheck("python runtime", HealthCheckStatus.Fail, diag.Summary), diag.Remediation);
        }

        if (stampState is null)
        {
            Add(new HealthCheck("runtime stamp", HealthCheckStatus.Skip, "only tracked for ManagedVenv mode"));
        }
        else
        {
            var (status, detail, remediation) = stampState.Value switch
            {
                SpeakerLabelingRuntimeState.Ready =>
                    (HealthCheckStatus.Ok, "runtime recorded and current", (string?)null),
                SpeakerLabelingRuntimeState.SetupNeeded =>
                    (HealthCheckStatus.Fail, "no runtime record — not set up", "Run setup to install the speaker-labeling runtime."),
                SpeakerLabelingRuntimeState.RepairNeeded =>
                    (HealthCheckStatus.Fail, "runtime record is unreadable", "Run setup to repair the speaker-labeling runtime."),
                SpeakerLabelingRuntimeState.Stale =>
                    (HealthCheckStatus.Fail, "requirements or sidecar changed since setup", "Run setup to update the speaker-labeling runtime."),
                _ => (HealthCheckStatus.Fail, "unknown runtime state", "Run setup."),
            };
            Add(new HealthCheck("runtime stamp", status, detail), remediation);
        }

        Add(tokenPresent
            ? new HealthCheck("hugging face token", HealthCheckStatus.Ok, "HUGGING_FACE_HUB_TOKEN is set")
            : new HealthCheck("hugging face token", HealthCheckStatus.Skip,
                "not set — needed to download the model if it is not cached"));

        if (modelCached)
        {
            Add(new HealthCheck("model cache", HealthCheckStatus.Ok, $"{options.ModelId} is cached"));
        }
        else
        {
            var diag = SpeakerLabelingDiagnostics.ForCode(SpeakerLabelingDiagnosticCode.ModelNotCached);
            Add(new HealthCheck("model cache", HealthCheckStatus.Fail, diag.Summary), diag.Remediation);
        }

        // These require running the interpreter and are produced by the smoke-test work.
        Add(new HealthCheck("dependency imports", HealthCheckStatus.Skip,
            "torch / pyannote import not checked here (requires running the runtime)"));
        Add(new HealthCheck("sidecar smoke test", HealthCheckStatus.Skip,
            "not run here (requires running the runtime)"));

        var isReady = checks.All(c => c.Status != HealthCheckStatus.Fail);
        return new SpeakerLabelingHealthReport(isReady, checks, isReady ? null : nextAction);
    }
}
