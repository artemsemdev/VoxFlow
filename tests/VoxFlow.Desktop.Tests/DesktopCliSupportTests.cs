using VoxFlow.Desktop.Services;
using Xunit;

namespace VoxFlow.Desktop.Tests;

public sealed class DesktopCliSupportTests
{
    [Fact]
    public void ExtractSuccessMetadata_ParsesLanguageAndSegmentCount()
    {
        var metadata = DesktopCliSupport.ExtractSuccessMetadata(
            """
            Starting transcription...
            Done. Language: English (en), Segments: 12
            """);

        Assert.Equal("English (en)", metadata.DetectedLanguage);
        Assert.Equal(12, metadata.AcceptedSegmentCount);
    }

    [Fact]
    public void ExtractFailureMessage_PrefersFailCheckLines()
    {
        var message = DesktopCliSupport.ExtractFailureMessage(
            """
            === Startup Validation ===
            [FAIL] Whisper runtime: Unsupported runtime
            Startup validation failed. Transcription will not start.
            """);

        Assert.Contains("Whisper runtime: Unsupported runtime", message);
    }

    [Fact]
    public void TryParseProgressUpdate_ParsesStructuredProgressEnvelope()
    {
        var line =
            """
            VOXFLOW_PROGRESS {"Stage":"Transcribing","PercentComplete":47.5,"ElapsedMilliseconds":12345,"Message":"Transcribing English","CurrentLanguage":"English","BatchFileIndex":null,"BatchFileTotal":null}
            """;

        var parsed = DesktopCliSupport.TryParseProgressUpdate(line, out var update);

        Assert.True(parsed);
        Assert.NotNull(update);
        Assert.Equal(VoxFlow.Core.Models.ProgressStage.Transcribing, update!.Stage);
        Assert.Equal(47.5, update.PercentComplete);
        Assert.Equal(TimeSpan.FromMilliseconds(12345), update.Elapsed);
        Assert.Equal("Transcribing English", update.Message);
        Assert.Equal("English", update.CurrentLanguage);
    }

    [Fact]
    public void ResolveBuiltCliAssemblyPath_ReturnsNullWhenCliOutputIsMissing()
    {
        var repositoryRoot = Path.Combine(Path.GetTempPath(), $"voxflow-cli-missing-{Guid.NewGuid():N}");
        Directory.CreateDirectory(repositoryRoot);

        try
        {
            Assert.Null(DesktopCliSupport.ResolveBuiltCliAssemblyPath(repositoryRoot));
        }
        finally
        {
            Directory.Delete(repositoryRoot, recursive: true);
        }
    }

    [Fact]
    public void ResolveBundledCliAssemblyPath_ReturnsBundledAssemblyWhenPresent()
    {
        var baseDirectory = Path.Combine(Path.GetTempPath(), $"voxflow-cli-bundle-{Guid.NewGuid():N}");
        var cliDirectory = Path.Combine(baseDirectory, "cli");
        Directory.CreateDirectory(cliDirectory);
        var assemblyPath = Path.Combine(cliDirectory, "VoxFlow.Cli.dll");
        File.WriteAllText(assemblyPath, string.Empty);

        try
        {
            Assert.Equal(assemblyPath, DesktopCliSupport.ResolveBundledCliAssemblyPath(baseDirectory));
        }
        finally
        {
            Directory.Delete(baseDirectory, recursive: true);
        }
    }
}
