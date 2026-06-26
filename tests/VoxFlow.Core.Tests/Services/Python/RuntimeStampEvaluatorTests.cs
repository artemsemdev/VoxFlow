using System;
using System.IO;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services.Python;
using Xunit;

namespace VoxFlow.Core.Tests.Services.Python;

public sealed class RuntimeFingerprintTests : IDisposable
{
    private readonly string _dir;

    public RuntimeFingerprintTests()
    {
        _dir = Directory.CreateDirectory(
            Path.Combine(Path.GetTempPath(), "voxflow-fp-" + Guid.NewGuid().ToString("N"))).FullName;
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { /* best effort */ }
    }

    private string WriteFile(string name, string content)
    {
        var path = Path.Combine(_dir, name);
        File.WriteAllText(path, content);
        return path;
    }

    [Fact]
    public void HashFile_IsStableForSameContent_AndPrefixed()
    {
        var a = WriteFile("a.txt", "pyannote.audio==3.1\ntorch==2.2");
        var b = WriteFile("b.txt", "pyannote.audio==3.1\ntorch==2.2");

        var ha = RuntimeFingerprint.HashFile(a);
        var hb = RuntimeFingerprint.HashFile(b);

        Assert.StartsWith("sha256:", ha);
        Assert.Equal(ha, hb);
    }

    [Fact]
    public void HashFile_DiffersForDifferentContent()
    {
        var a = WriteFile("a.txt", "torch==2.2");
        var b = WriteFile("b.txt", "torch==2.3");

        Assert.NotEqual(RuntimeFingerprint.HashFile(a), RuntimeFingerprint.HashFile(b));
    }

    [Fact]
    public void HashFile_MissingFile_Throws()
    {
        Assert.Throws<FileNotFoundException>(() =>
            RuntimeFingerprint.HashFile(Path.Combine(_dir, "nope.txt")));
    }
}

public sealed class RuntimeStampEvaluatorTests
{
    private static RuntimeStampReadResult Ok(
        int schema = SpeakerLabelingRuntimeStamp.CurrentSchemaVersion,
        string? reqHash = "sha256:req",
        string? sidecarHash = "sha256:sidecar")
        => new(RuntimeStampReadStatus.Ok, new SpeakerLabelingRuntimeStamp(
            SchemaVersion: schema,
            RuntimeId: "speaker-labeling-managed-venv-v1",
            PythonExecutable: "/p",
            PythonVersion: "3.11",
            RequirementsHash: reqHash,
            SidecarHash: sidecarHash,
            ModelId: "pyannote/speaker-diarization-3.1",
            ModelCacheState: "verified",
            ValidatedAt: DateTimeOffset.UnixEpoch));

    [Fact]
    public void Missing_MapsToSetupNeeded()
    {
        var state = RuntimeStampEvaluator.Evaluate(
            new RuntimeStampReadResult(RuntimeStampReadStatus.Missing, null), "sha256:req", "sha256:sidecar");
        Assert.Equal(SpeakerLabelingRuntimeState.SetupNeeded, state);
    }

    [Fact]
    public void Corrupt_MapsToRepairNeeded()
    {
        var state = RuntimeStampEvaluator.Evaluate(
            new RuntimeStampReadResult(RuntimeStampReadStatus.Corrupt, null), "sha256:req", "sha256:sidecar");
        Assert.Equal(SpeakerLabelingRuntimeState.RepairNeeded, state);
    }

    [Fact]
    public void UnknownSchema_MapsToRepairNeeded()
    {
        var state = RuntimeStampEvaluator.Evaluate(Ok(schema: 999), "sha256:req", "sha256:sidecar");
        Assert.Equal(SpeakerLabelingRuntimeState.RepairNeeded, state);
    }

    [Fact]
    public void MatchingHashes_MapsToReady()
    {
        var state = RuntimeStampEvaluator.Evaluate(Ok(), "sha256:req", "sha256:sidecar");
        Assert.Equal(SpeakerLabelingRuntimeState.Ready, state);
    }

    [Fact]
    public void RequirementsHashMismatch_MapsToStale()
    {
        var state = RuntimeStampEvaluator.Evaluate(Ok(reqHash: "sha256:OLD"), "sha256:req", "sha256:sidecar");
        Assert.Equal(SpeakerLabelingRuntimeState.Stale, state);
    }

    [Fact]
    public void SidecarHashMismatch_MapsToStale()
    {
        var state = RuntimeStampEvaluator.Evaluate(Ok(sidecarHash: "sha256:OLD"), "sha256:req", "sha256:sidecar");
        Assert.Equal(SpeakerLabelingRuntimeState.Stale, state);
    }
}
