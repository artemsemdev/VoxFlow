using System;
using System.IO;
using System.Text.Json;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services.Python;
using Xunit;

namespace VoxFlow.Core.Tests.Services.Python;

public sealed class RuntimeStampStoreTests : IDisposable
{
    private readonly string _dir;
    private readonly string _path;

    public RuntimeStampStoreTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "voxflow-stamp-" + Guid.NewGuid().ToString("N"));
        _path = Path.Combine(_dir, "nested", "speaker-labeling-runtime.json");
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { /* best effort */ }
    }

    private static SpeakerLabelingRuntimeStamp Sample() => new(
        SchemaVersion: SpeakerLabelingRuntimeStamp.CurrentSchemaVersion,
        RuntimeId: "speaker-labeling-managed-venv-v1",
        PythonExecutable: "/path/to/python",
        PythonVersion: "3.11.9",
        RequirementsHash: "sha256:aaa",
        SidecarHash: "sha256:bbb",
        ModelId: "pyannote/speaker-diarization-3.1",
        ModelCacheState: "verified",
        ValidatedAt: new DateTimeOffset(2026, 6, 27, 0, 0, 0, TimeSpan.Zero));

    [Fact]
    public void Read_MissingFile_ReturnsMissing()
    {
        var store = new RuntimeStampStore(_path);

        var result = store.Read();

        Assert.Equal(RuntimeStampReadStatus.Missing, result.Status);
        Assert.Null(result.Stamp);
    }

    [Fact]
    public void Write_ThenRead_RoundTrips_AndCreatesDirectory()
    {
        var store = new RuntimeStampStore(_path);
        var stamp = Sample();

        store.Write(stamp);

        Assert.True(File.Exists(_path));
        var result = store.Read();
        Assert.Equal(RuntimeStampReadStatus.Ok, result.Status);
        Assert.Equal(stamp, result.Stamp);
    }

    [Fact]
    public void Read_CorruptJson_ReturnsCorrupt()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, "{ this is not valid json ]");
        var store = new RuntimeStampStore(_path);

        var result = store.Read();

        Assert.Equal(RuntimeStampReadStatus.Corrupt, result.Status);
        Assert.Null(result.Stamp);
    }

    [Fact]
    public void Read_EmptyFile_ReturnsCorrupt()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, "   ");
        var store = new RuntimeStampStore(_path);

        Assert.Equal(RuntimeStampReadStatus.Corrupt, store.Read().Status);
    }

    [Fact]
    public void Delete_RemovesFile_AndIsIdempotent()
    {
        var store = new RuntimeStampStore(_path);
        store.Write(Sample());
        Assert.True(File.Exists(_path));

        store.Delete();
        Assert.False(File.Exists(_path));

        // Deleting again must not throw.
        store.Delete();
    }

    [Fact]
    public void DefaultStampPath_IsAbsolute_UnderVoxFlow_AndJson()
    {
        var path = DefaultRuntimeStampPath.FilePath;

        Assert.True(Path.IsPathRooted(path));
        Assert.EndsWith("speaker-labeling-runtime.json", path);
        Assert.Contains("VoxFlow", path);
        // Sibling of python-runtime/, not nested inside it.
        Assert.DoesNotContain("python-runtime", path);
    }

    [Fact]
    public void SerializedStamp_ContainsNoSecretsAudioOrTranscript()
    {
        var store = new RuntimeStampStore(_path);
        store.Write(Sample());

        var json = File.ReadAllText(_path).ToLowerInvariant();

        Assert.DoesNotContain("token", json);
        Assert.DoesNotContain("secret", json);
        Assert.DoesNotContain("audio", json);
        Assert.DoesNotContain("transcript", json);
        Assert.DoesNotContain("wav", json);
    }
}
