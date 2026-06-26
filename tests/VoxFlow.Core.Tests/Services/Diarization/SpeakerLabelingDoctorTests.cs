using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services.Diarization;
using VoxFlow.Core.Services.Python;
using Xunit;

namespace VoxFlow.Core.Tests.Services.Diarization;

public sealed class SpeakerLabelingDoctorTests
{
    [Fact]
    public async Task ConfigurationLoadFailure_ReportsConfigFail_AndStopsEarly()
    {
        var preflight = new UnusedPreflight();
        var doctor = new SpeakerLabelingDoctor(
            new ThrowingConfigurationService(),
            preflight,
            new UnusedStampStore(),
            requirementsFilePath: "/nope/req.txt",
            sidecarScriptPath: "/nope/sidecar.py");

        var report = await doctor.CheckAsync(CancellationToken.None);

        Assert.False(report.IsReady);
        var config = Assert.Single(report.Checks);
        Assert.Equal("configuration", config.Name);
        Assert.Equal(HealthCheckStatus.Fail, config.Status);
        Assert.NotNull(report.NextAction);
        // Preflight must not be consulted once config is unreadable.
        Assert.False(preflight.WasCalled);
    }

    private sealed class ThrowingConfigurationService : IConfigurationService
    {
        public Task<TranscriptionOptions> LoadAsync(string? configurationPath = null)
            => throw new InvalidOperationException("bad config");

        public IReadOnlyList<SupportedLanguage> GetSupportedLanguages(string? configurationPath = null)
            => Array.Empty<SupportedLanguage>();
    }

    private sealed class UnusedPreflight : ISpeakerLabelingPreflight
    {
        public bool WasCalled { get; private set; }

        public Task<PythonRuntimeStatus> GetRuntimeStatusAsync(SpeakerLabelingOptions options, CancellationToken cancellationToken)
        {
            WasCalled = true;
            return Task.FromResult(PythonRuntimeStatus.Ready("/p", "3.11"));
        }

        public bool IsModelCached(string modelId)
        {
            WasCalled = true;
            return true;
        }
    }

    private sealed class UnusedStampStore : IRuntimeStampStore
    {
        public RuntimeStampReadResult Read() => new(RuntimeStampReadStatus.Missing, null);
        public void Write(SpeakerLabelingRuntimeStamp stamp) { }
        public void Delete() { }
    }
}
