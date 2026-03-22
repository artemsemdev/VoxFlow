using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using Xunit;

public sealed class BatchSummaryWriterTests
{
    [Fact]
    public void BuildSummaryText_AllSucceeded_ShowsCorrectCounts()
    {
        var results = new List<FileProcessingResult>
        {
            new("/input/a.m4a", "/output/a.txt", FileProcessingStatus.Success, null, TimeSpan.FromSeconds(30), "English"),
            new("/input/b.m4a", "/output/b.txt", FileProcessingStatus.Success, null, TimeSpan.FromSeconds(45), "Russian")
        };

        var summary = BatchSummaryWriter.BuildSummaryText(results);

        Assert.Contains("Total files:     2", summary, StringComparison.Ordinal);
        Assert.Contains("Succeeded:       2", summary, StringComparison.Ordinal);
        Assert.Contains("Failed:          0", summary, StringComparison.Ordinal);
        Assert.Contains("Skipped:         0", summary, StringComparison.Ordinal);
        Assert.Contains("[OK]", summary, StringComparison.Ordinal);
        Assert.Contains("a.m4a", summary, StringComparison.Ordinal);
        Assert.Contains("b.m4a", summary, StringComparison.Ordinal);
    }

    [Fact]
    public void BuildSummaryText_MixedResults_ShowsCorrectCountsAndStatuses()
    {
        var results = new List<FileProcessingResult>
        {
            new("/input/ok.m4a", "/output/ok.txt", FileProcessingStatus.Success, null, TimeSpan.FromSeconds(60), "English"),
            new("/input/bad.m4a", "/output/bad.txt", FileProcessingStatus.Failed, "Conversion failed", TimeSpan.FromSeconds(5), null),
            new("/input/empty.m4a", "/output/empty.txt", FileProcessingStatus.Skipped, "File is empty (0 bytes)", TimeSpan.Zero, null)
        };

        var summary = BatchSummaryWriter.BuildSummaryText(results);

        Assert.Contains("Total files:     3", summary, StringComparison.Ordinal);
        Assert.Contains("Succeeded:       1", summary, StringComparison.Ordinal);
        Assert.Contains("Failed:          1", summary, StringComparison.Ordinal);
        Assert.Contains("Skipped:         1", summary, StringComparison.Ordinal);
        Assert.Contains("[OK]", summary, StringComparison.Ordinal);
        Assert.Contains("[FAILED]", summary, StringComparison.Ordinal);
        Assert.Contains("[SKIPPED]", summary, StringComparison.Ordinal);
        Assert.Contains("Conversion failed", summary, StringComparison.Ordinal);
    }

    [Fact]
    public void BuildSummaryText_EmptyBatch_HandlesEdgeCase()
    {
        var results = new List<FileProcessingResult>();

        var summary = BatchSummaryWriter.BuildSummaryText(results);

        Assert.Contains("Total files:     0", summary, StringComparison.Ordinal);
        Assert.Contains("Succeeded:       0", summary, StringComparison.Ordinal);
        Assert.Contains("Batch Processing Summary", summary, StringComparison.Ordinal);
    }

    [Fact]
    public async Task WriteAsync_WritesFileSuccessfully()
    {
        using var directory = new TemporaryDirectory();
        var summaryPath = Path.Combine(directory.Path, "summary.txt");
        var results = new List<FileProcessingResult>
        {
            new("/input/test.m4a", "/output/test.txt", FileProcessingStatus.Success, null, TimeSpan.FromMinutes(1), "English")
        };

        await BatchSummaryWriter.WriteAsync(summaryPath, results);

        Assert.True(File.Exists(summaryPath));
        var content = await File.ReadAllTextAsync(summaryPath);
        Assert.Contains("Batch Processing Summary", content, StringComparison.Ordinal);
        Assert.Contains("test.m4a", content, StringComparison.Ordinal);
    }
}
