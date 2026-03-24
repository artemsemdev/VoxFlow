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
}
