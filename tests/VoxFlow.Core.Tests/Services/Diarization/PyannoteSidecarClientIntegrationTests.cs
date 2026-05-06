using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services.Diarization;
using VoxFlow.Core.Services.Python;
using Xunit;
using Xunit.Abstractions;

namespace VoxFlow.Core.Tests.Services.Diarization;

/// <summary>
/// End-to-end integration tests for <see cref="PyannoteSidecarClient"/>
/// against the real <c>voxflow_diarize.py</c> script, real
/// <see cref="SystemPythonRuntime"/>, and real audio fixtures. The class is
/// tagged so CI/dev can opt in/out via <c>--filter Category=RequiresPython</c>;
/// fixture-backed tests use <see cref="SkippableFactAttribute"/> to stay green
/// before the audio fixtures land in P0.8.
/// </summary>
[Trait("Category", "RequiresPython")]
public sealed class PyannoteSidecarClientIntegrationTests
{
    private readonly ITestOutputHelper _output;

    public PyannoteSidecarClientIntegrationTests(ITestOutputHelper output)
    {
        _output = output;
    }

    private static string ScriptPath => Path.Combine(
        AppContext.BaseDirectory, "python", "voxflow_diarize.py");

    private static string SingleSpeakerFixturePath => Path.Combine(
        AppContext.BaseDirectory, "fixtures", "sidecar", "audio", "obama-speech-1spk-10s.wav");

    private static string TwoSpeakerFixturePath => Path.Combine(
        AppContext.BaseDirectory, "fixtures", "sidecar", "audio", "libricss-2spk-10s.wav");

    private static string ThreeSpeakerFixturePath => Path.Combine(
        AppContext.BaseDirectory, "fixtures", "sidecar", "audio", "libricss-3spk-10s.wav");

    [SkippableFact]
    public async Task DiarizeAsync_RealSidecar_SingleSpeakerWav_Returns1Speaker()
    {
        LoudSkip.IfNot(_output, RequiresPythonOptedIn(), OptInSkipReason);
        LoudSkip.IfNot(_output, File.Exists(ScriptPath), $"sidecar script missing at {ScriptPath}");
        LoudSkip.IfNot(_output, await SystemPythonRuntimeReadyAsync(),
            "system python3 not ready (missing or below required 3.10)");
        LoudSkip.IfNot(_output, File.Exists(SingleSpeakerFixturePath),
            "fixture not yet committed; will be enabled in P0.8");

        var client = CreateClient();
        var result = await client.DiarizeAsync(
            new DiarizationRequest(SingleSpeakerFixturePath),
            progress: null,
            CancellationToken.None);

        Assert.Equal(1, result.Version);
        Assert.Single(result.Speakers);
    }

    [SkippableFact]
    public async Task DiarizeAsync_RealSidecar_TwoSpeakerWav_Returns2Speakers()
    {
        LoudSkip.IfNot(_output, RequiresPythonOptedIn(), OptInSkipReason);
        LoudSkip.IfNot(_output, File.Exists(ScriptPath), $"sidecar script missing at {ScriptPath}");
        LoudSkip.IfNot(_output, await SystemPythonRuntimeReadyAsync(),
            "system python3 not ready (missing or below required 3.10)");
        LoudSkip.IfNot(_output, File.Exists(TwoSpeakerFixturePath),
            "fixture not yet committed; will be enabled in P0.8");

        var client = CreateClient();
        var result = await client.DiarizeAsync(
            new DiarizationRequest(TwoSpeakerFixturePath),
            progress: null,
            CancellationToken.None);

        Assert.Equal(2, result.Speakers.Count);
    }

    [SkippableFact]
    public async Task DiarizeAsync_RealSidecar_ThreeSpeakerWav_ReturnsAtLeast3Speakers()
    {
        LoudSkip.IfNot(_output, RequiresPythonOptedIn(), OptInSkipReason);
        LoudSkip.IfNot(_output, File.Exists(ScriptPath), $"sidecar script missing at {ScriptPath}");
        LoudSkip.IfNot(_output, await SystemPythonRuntimeReadyAsync(),
            "system python3 not ready (missing or below required 3.10)");
        LoudSkip.IfNot(_output, File.Exists(ThreeSpeakerFixturePath),
            "fixture not yet committed; will be enabled in P0.8");

        var client = CreateClient();
        var result = await client.DiarizeAsync(
            new DiarizationRequest(ThreeSpeakerFixturePath),
            progress: null,
            CancellationToken.None);

        Assert.True(result.Speakers.Count >= 3, $"expected >=3 speakers, got {result.Speakers.Count}");
    }

    private static PyannoteSidecarClient CreateClient()
    {
        var launcher = new DefaultProcessLauncher();
        var runtime = new SystemPythonRuntime(launcher);
        return new PyannoteSidecarClient(runtime, launcher, ScriptPath, TimeSpan.FromMinutes(5));
    }

    private const string OptInEnvironmentVariable = "VOXFLOW_RUN_REQUIRES_PYTHON_TESTS";
    private const string OptInSkipReason =
        "Set VOXFLOW_RUN_REQUIRES_PYTHON_TESTS=1 to run tests that require a real python3 with pyannote installed.";

    private static bool RequiresPythonOptedIn()
        => string.Equals(
            Environment.GetEnvironmentVariable(OptInEnvironmentVariable),
            "1",
            StringComparison.Ordinal);

    private static async Task<bool> SystemPythonRuntimeReadyAsync()
    {
        try
        {
            var runtime = new SystemPythonRuntime(new DefaultProcessLauncher());
            var status = await runtime.GetStatusAsync(CancellationToken.None);
            return status.IsReady;
        }
        catch
        {
            return false;
        }
    }
}
