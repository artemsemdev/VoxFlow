using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using VoxFlow.Cli;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services.Diarization;
using Xunit;

namespace VoxFlow.Cli.Tests;

public sealed class DoctorCommandTests
{
    private static SpeakerLabelingHealthReport Report(bool ready, string? nextAction = null) => new(
        IsReady: ready,
        Checks: new[]
        {
            new HealthCheck("configuration", HealthCheckStatus.Ok, "loaded"),
            new HealthCheck("python runtime", ready ? HealthCheckStatus.Ok : HealthCheckStatus.Fail, "3.11 at /p"),
            new HealthCheck("sidecar smoke test", HealthCheckStatus.Skip, "not run here"),
        },
        NextAction: nextAction);

    [Fact]
    public void RenderText_ShowsStatusesNamesAndNextAction()
    {
        var text = DoctorCommand.RenderText(Report(ready: false, nextAction: "Run setup."));

        Assert.Contains("Speaker labeling: not ready", text);
        Assert.Contains("OK", text);
        Assert.Contains("FAIL", text);
        Assert.Contains("SKIP", text);
        Assert.Contains("python runtime", text);
        Assert.Contains("Next action:", text);
        Assert.Contains("Run setup.", text);
    }

    [Fact]
    public void RenderText_Ready_OmitsNextAction()
    {
        var text = DoctorCommand.RenderText(Report(ready: true));

        Assert.Contains("Speaker labeling: ready", text);
        Assert.DoesNotContain("Next action:", text);
    }

    [Fact]
    public void RenderJson_IsValidJson_WithReadyAndChecks()
    {
        var json = DoctorCommand.RenderJson(Report(ready: true));

        using var doc = JsonDocument.Parse(json);
        Assert.True(doc.RootElement.GetProperty("IsReady").GetBoolean());
        Assert.NotEqual(0, doc.RootElement.GetProperty("Checks").GetArrayLength());
    }

    [Fact]
    public async Task RunAsync_Ready_ReturnsZero()
    {
        var code = await DoctorCommand.RunAsync(new FakeDoctor(Report(ready: true)), new[] { "speakers" }, CancellationToken.None);
        Assert.Equal(0, code);
    }

    [Fact]
    public async Task RunAsync_NotReady_ReturnsOne()
    {
        var code = await DoctorCommand.RunAsync(new FakeDoctor(Report(ready: false, "x")), new[] { "speakers" }, CancellationToken.None);
        Assert.Equal(1, code);
    }

    [Fact]
    public async Task RunAsync_UnknownTarget_ReturnsTwo_AndDoesNotRunDoctor()
    {
        var doctor = new FakeDoctor(Report(ready: true));
        var code = await DoctorCommand.RunAsync(doctor, new[] { "frobnicate" }, CancellationToken.None);

        Assert.Equal(2, code);
        Assert.False(doctor.WasCalled);
    }

    private sealed class FakeDoctor : ISpeakerLabelingDoctor
    {
        private readonly SpeakerLabelingHealthReport _report;
        public bool WasCalled { get; private set; }
        public FakeDoctor(SpeakerLabelingHealthReport report) => _report = report;

        public Task<SpeakerLabelingHealthReport> CheckAsync(CancellationToken cancellationToken)
        {
            WasCalled = true;
            return Task.FromResult(_report);
        }
    }
}
