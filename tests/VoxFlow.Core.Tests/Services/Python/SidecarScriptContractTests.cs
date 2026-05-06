using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;
using Xunit.Abstractions;

namespace VoxFlow.Core.Tests.Services.Python;

/// <summary>
/// Contract tests for <c>voxflow_diarize.py</c> (ADR-024 Phase 0, P0.5).
/// Exercises the sidecar script directly via python3, without the .NET client.
/// The fixture-backed tests use <see cref="SkippableFactAttribute"/> so the suite
/// stays green on machines that don't yet have the audio fixtures from P0.8
/// or don't have python3/pyannote installed.
/// </summary>
[Trait("Category", "RequiresPython")]
public sealed class SidecarScriptContractTests
{
    private readonly ITestOutputHelper _output;

    public SidecarScriptContractTests(ITestOutputHelper output)
    {
        _output = output;
    }

    private static string ScriptPath => Path.Combine(
        AppContext.BaseDirectory, "python", "voxflow_diarize.py");

    private static string SingleSpeakerFixturePath => Path.Combine(
        AppContext.BaseDirectory, "fixtures", "sidecar", "audio", "obama-speech-1spk-10s.wav");

    private static string TwoSpeakerFixturePath => Path.Combine(
        AppContext.BaseDirectory, "fixtures", "sidecar", "audio", "libricss-2spk-10s.wav");

    [SkippableFact]
    public async Task RunAgainstSingleSpeakerWav_ReturnsOkResponse_WithOneSpeaker()
    {
        LoudSkip.IfNot(_output, RequiresPythonOptedIn(), OptInSkipReason);
        LoudSkip.IfNot(_output, Python3Available(), "python3 not available on PATH");
        LoudSkip.IfNot(_output, File.Exists(ScriptPath), $"sidecar script missing at {ScriptPath}");
        LoudSkip.IfNot(_output, File.Exists(SingleSpeakerFixturePath),
            "fixture not yet committed; will be enabled in P0.8");

        var result = await RunSidecarAsync(
            JsonSerializer.Serialize(new { version = 1, wavPath = SingleSpeakerFixturePath }));

        Assert.Equal(0, result.ExitCode);
        using var doc = JsonDocument.Parse(result.StdOut);
        var root = doc.RootElement;
        Assert.Equal(1, root.GetProperty("version").GetInt32());
        Assert.Equal("ok", root.GetProperty("status").GetString());
        Assert.Equal(1, root.GetProperty("speakers").GetArrayLength());
    }

    [SkippableFact]
    public async Task RunAgainstTwoSpeakerWav_ReturnsOkResponse_WithTwoSpeakers()
    {
        LoudSkip.IfNot(_output, RequiresPythonOptedIn(), OptInSkipReason);
        LoudSkip.IfNot(_output, Python3Available(), "python3 not available on PATH");
        LoudSkip.IfNot(_output, File.Exists(ScriptPath), $"sidecar script missing at {ScriptPath}");
        LoudSkip.IfNot(_output, File.Exists(TwoSpeakerFixturePath),
            "fixture not yet committed; will be enabled in P0.8");

        var result = await RunSidecarAsync(
            JsonSerializer.Serialize(new { version = 1, wavPath = TwoSpeakerFixturePath }));

        Assert.Equal(0, result.ExitCode);
        using var doc = JsonDocument.Parse(result.StdOut);
        var root = doc.RootElement;
        Assert.Equal("ok", root.GetProperty("status").GetString());
        Assert.Equal(2, root.GetProperty("speakers").GetArrayLength());
    }

    [SkippableFact]
    public async Task RunAgainstMissingWav_ReturnsErrorResponse()
    {
        LoudSkip.IfNot(_output, RequiresPythonOptedIn(), OptInSkipReason);
        LoudSkip.IfNot(_output, Python3Available(), "python3 not available on PATH");
        LoudSkip.IfNot(_output, File.Exists(ScriptPath), $"sidecar script missing at {ScriptPath}");

        var missing = Path.Combine(Path.GetTempPath(), $"voxflow-missing-{Guid.NewGuid():N}.wav");
        var result = await RunSidecarAsync(
            JsonSerializer.Serialize(new { version = 1, wavPath = missing }));

        Assert.Equal(0, result.ExitCode);
        using var doc = JsonDocument.Parse(result.StdOut);
        var root = doc.RootElement;
        Assert.Equal("error", root.GetProperty("status").GetString());
        var message = root.GetProperty("error").GetString() ?? string.Empty;
        Assert.Contains("wav", message, StringComparison.OrdinalIgnoreCase);
    }

    [SkippableFact]
    public async Task RunWithMalformedJsonRequest_ReturnsErrorResponse_AndExitsNonZero()
    {
        LoudSkip.IfNot(_output, RequiresPythonOptedIn(), OptInSkipReason);
        LoudSkip.IfNot(_output, Python3Available(), "python3 not available on PATH");
        LoudSkip.IfNot(_output, File.Exists(ScriptPath), $"sidecar script missing at {ScriptPath}");

        var result = await RunSidecarAsync("{ this is not json");

        Assert.NotEqual(0, result.ExitCode);
        using var doc = JsonDocument.Parse(result.StdOut);
        Assert.Equal("error", doc.RootElement.GetProperty("status").GetString());
    }

    private static async Task<(int ExitCode, string StdOut, string StdErr)> RunSidecarAsync(string stdin)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "python3",
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        psi.ArgumentList.Add(ScriptPath);

        using var process = Process.Start(psi)
            ?? throw new InvalidOperationException("failed to start python3");

        var stdOutTask = process.StandardOutput.ReadToEndAsync();
        var stdErrTask = process.StandardError.ReadToEndAsync();

        await process.StandardInput.WriteAsync(stdin);
        process.StandardInput.Close();

        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        await process.WaitForExitAsync(cts.Token);

        var stdOut = await stdOutTask;
        var stdErr = await stdErrTask;
        return (process.ExitCode, stdOut, stdErr);
    }

    private const string OptInEnvironmentVariable = "VOXFLOW_RUN_REQUIRES_PYTHON_TESTS";
    private const string OptInSkipReason =
        "Set VOXFLOW_RUN_REQUIRES_PYTHON_TESTS=1 to run tests that require a real python3 with pyannote installed.";

    private static bool RequiresPythonOptedIn()
        => string.Equals(
            Environment.GetEnvironmentVariable(OptInEnvironmentVariable),
            "1",
            StringComparison.Ordinal);

    private static readonly Version MinimumPythonVersion = new(3, 10);

    private static bool Python3Available()
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "python3",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            psi.ArgumentList.Add("--version");
            using var process = Process.Start(psi);
            if (process is null)
            {
                return false;
            }
            var stdOut = process.StandardOutput.ReadToEnd();
            var stdErr = process.StandardError.ReadToEnd();
            process.WaitForExit(5000);
            if (process.ExitCode != 0)
            {
                return false;
            }

            // `python3 --version` prints "Python X.Y.Z" to stdout on 3.4+
            // and to stderr on older builds — accept either.
            var versionText = !string.IsNullOrWhiteSpace(stdOut) ? stdOut : stdErr;
            var match = System.Text.RegularExpressions.Regex.Match(versionText, @"Python (\d+)\.(\d+)");
            if (!match.Success)
            {
                return false;
            }
            var version = new Version(int.Parse(match.Groups[1].Value), int.Parse(match.Groups[2].Value));
            return version >= MinimumPythonVersion;
        }
        catch
        {
            return false;
        }
    }
}
