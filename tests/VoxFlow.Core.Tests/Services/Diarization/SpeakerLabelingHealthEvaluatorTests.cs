using System.Linq;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services.Diarization;
using VoxFlow.Core.Services.Python;
using Xunit;

namespace VoxFlow.Core.Tests.Services.Diarization;

public sealed class SpeakerLabelingHealthEvaluatorTests
{
    private static SpeakerLabelingOptions Options(PythonRuntimeMode mode = PythonRuntimeMode.ManagedVenv)
        => new(Enabled: true, TimeoutSeconds: 600, RuntimeMode: mode, ModelId: "pyannote/speaker-diarization-3.1");

    private static HealthCheck Check(SpeakerLabelingHealthReport report, string name)
        => report.Checks.Single(c => c.Name == name);

    [Fact]
    public void AllGood_IsReady_WithNoNextAction()
    {
        var report = SpeakerLabelingHealthEvaluator.Evaluate(
            Options(),
            PythonRuntimeStatus.Ready("/venv/bin/python3", "3.11.9"),
            modelCached: true,
            tokenPresent: true,
            stampState: SpeakerLabelingRuntimeState.Ready);

        Assert.True(report.IsReady);
        Assert.Null(report.NextAction);
        Assert.DoesNotContain(report.Checks, c => c.Status == HealthCheckStatus.Fail);
        Assert.Equal(HealthCheckStatus.Ok, Check(report, "python runtime").Status);
        Assert.Equal(HealthCheckStatus.Ok, Check(report, "model cache").Status);
    }

    [Fact]
    public void RuntimeNotReady_FailsRuntime_AndSurfacesItsRemediation()
    {
        var status = PythonRuntimeStatus.NotReady("python3 not found", SpeakerLabelingDiagnosticCode.PythonNotFound);

        var report = SpeakerLabelingHealthEvaluator.Evaluate(
            Options(), status, modelCached: true, tokenPresent: true, stampState: SpeakerLabelingRuntimeState.Ready);

        Assert.False(report.IsReady);
        Assert.Equal(HealthCheckStatus.Fail, Check(report, "python runtime").Status);
        Assert.Contains("Install Python", report.NextAction);
    }

    [Fact]
    public void ModelNotCached_Fails_AndIsNotReady()
    {
        var report = SpeakerLabelingHealthEvaluator.Evaluate(
            Options(), PythonRuntimeStatus.Ready("/p", "3.11"),
            modelCached: false, tokenPresent: true, stampState: SpeakerLabelingRuntimeState.Ready);

        Assert.False(report.IsReady);
        Assert.Equal(HealthCheckStatus.Fail, Check(report, "model cache").Status);
        Assert.NotNull(report.NextAction);
    }

    [Fact]
    public void StampMissing_Fails_WithSetupNextAction()
    {
        var report = SpeakerLabelingHealthEvaluator.Evaluate(
            Options(), PythonRuntimeStatus.Ready("/p", "3.11"),
            modelCached: true, tokenPresent: true, stampState: SpeakerLabelingRuntimeState.SetupNeeded);

        Assert.False(report.IsReady);
        Assert.Equal(HealthCheckStatus.Fail, Check(report, "runtime stamp").Status);
        Assert.Contains("setup", report.NextAction, System.StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void TokenAbsent_IsSkip_NotFail_AndDoesNotBlockReadiness()
    {
        var report = SpeakerLabelingHealthEvaluator.Evaluate(
            Options(), PythonRuntimeStatus.Ready("/p", "3.11"),
            modelCached: true, tokenPresent: false, stampState: SpeakerLabelingRuntimeState.Ready);

        Assert.Equal(HealthCheckStatus.Skip, Check(report, "hugging face token").Status);
        Assert.True(report.IsReady);
    }

    [Fact]
    public void NonManagedMode_StampCheckIsSkipped()
    {
        var report = SpeakerLabelingHealthEvaluator.Evaluate(
            Options(PythonRuntimeMode.SystemPython), PythonRuntimeStatus.Ready("/usr/bin/python3", "3.12"),
            modelCached: true, tokenPresent: true, stampState: null);

        Assert.Equal(HealthCheckStatus.Skip, Check(report, "runtime stamp").Status);
        Assert.True(report.IsReady);
    }

    [Fact]
    public void ImportsAndSmoke_AreAlwaysSkipped_PendingSmokeWork()
    {
        var report = SpeakerLabelingHealthEvaluator.Evaluate(
            Options(), PythonRuntimeStatus.Ready("/p", "3.11"),
            modelCached: true, tokenPresent: true, stampState: SpeakerLabelingRuntimeState.Ready);

        Assert.Equal(HealthCheckStatus.Skip, Check(report, "dependency imports").Status);
        Assert.Equal(HealthCheckStatus.Skip, Check(report, "sidecar smoke test").Status);
    }
}
