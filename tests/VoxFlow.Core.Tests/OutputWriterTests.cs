using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services;
using Xunit;

namespace VoxFlow.Core.Tests;

public sealed class OutputWriterTests
{
    [Fact]
    public void BuildOutputText_UsesLegacyTimestampFormat()
    {
        var segments = new[]
        {
            new FilteredSegment(
                TimeSpan.FromSeconds(1),
                TimeSpan.FromSeconds(2),
                "Hello",
                0.95)
        };

        var writer = new OutputWriter();
        var output = writer.BuildOutputText(segments);

        Assert.Equal("00:00:01->00:00:02: Hello" + Environment.NewLine, output);
    }

    [Fact]
    public void BuildOutputText_PreservesFractionalTimestamps()
    {
        var segments = new[]
        {
            new FilteredSegment(
                TimeSpan.FromMilliseconds(1200),
                TimeSpan.FromMilliseconds(3800),
                "Test",
                0.90)
        };

        var writer = new OutputWriter();
        var output = writer.BuildOutputText(segments);

        Assert.Contains("00:00:01.2000000->00:00:03.8000000: Test", output);
    }

    [Fact]
    public void BuildOutputText_ReturnsEmptyStringForNoSegments()
    {
        var writer = new OutputWriter();
        var output = writer.BuildOutputText(Array.Empty<FilteredSegment>());

        Assert.Equal(string.Empty, output);
    }

    [Fact]
    public void BuildOutputText_HandlesMultipleSegments()
    {
        var segments = new[]
        {
            new FilteredSegment(TimeSpan.FromSeconds(0), TimeSpan.FromSeconds(1), "First", 0.9),
            new FilteredSegment(TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2), "Second", 0.8),
            new FilteredSegment(TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(3), "Third", 0.7)
        };

        var writer = new OutputWriter();
        var output = writer.BuildOutputText(segments);

        var lines = output.Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal(3, lines.Length);
        Assert.StartsWith("00:00:00->00:00:01: First", lines[0]);
        Assert.StartsWith("00:00:01->00:00:02: Second", lines[1]);
        Assert.StartsWith("00:00:02->00:00:03: Third", lines[2]);
    }

    [Fact]
    public async Task WriteAsync_CreatesUtf8FileWithoutBom()
    {
        using var directory = new TemporaryDirectory();
        var resultPath = Path.Combine(directory.Path, "result.txt");
        var segments = new[]
        {
            new FilteredSegment(TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2), "Hello", 0.9)
        };

        var writer = new OutputWriter();
        await writer.WriteAsync(resultPath, segments);

        var bytes = await File.ReadAllBytesAsync(resultPath);
        // UTF-8 BOM is EF BB BF; verify it's absent.
        Assert.False(bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF,
            "Output file should not contain a UTF-8 BOM.");
        var content = await File.ReadAllTextAsync(resultPath);
        Assert.Contains("00:00:01->00:00:02: Hello", content);
    }

    [Fact]
    public async Task WriteAsync_ThrowsWhenCancellationIsRequestedBeforeWriting()
    {
        using var directory = new TemporaryDirectory();
        var resultPath = Path.Combine(directory.Path, "result.txt");
        var segments = new[]
        {
            new FilteredSegment(TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2), "Hello", 0.9)
        };

        var writer = new OutputWriter();
        using var cancellationTokenSource = new CancellationTokenSource();
        await cancellationTokenSource.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => writer.WriteAsync(resultPath, segments, cancellationTokenSource.Token));

        Assert.False(File.Exists(resultPath));
    }
}
