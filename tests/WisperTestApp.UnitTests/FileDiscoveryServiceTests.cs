using System;
using System.IO;
using System.Linq;
using Xunit;

public sealed class FileDiscoveryServiceTests
{
    [Fact]
    public void DiscoverInputFiles_DirectoryWithMatchingFiles_ReturnsSortedList()
    {
        using var directory = new TemporaryDirectory();
        var inputDir = Path.Combine(directory.Path, "input");
        var outputDir = Path.Combine(directory.Path, "output");
        Directory.CreateDirectory(inputDir);
        Directory.CreateDirectory(outputDir);

        File.WriteAllText(Path.Combine(inputDir, "charlie.m4a"), "audio data");
        File.WriteAllText(Path.Combine(inputDir, "alpha.m4a"), "audio data");
        File.WriteAllText(Path.Combine(inputDir, "bravo.m4a"), "audio data");

        var options = new BatchOptions(
            InputDirectory: inputDir,
            OutputDirectory: outputDir,
            TempDirectory: directory.Path,
            FilePattern: "*.m4a",
            StopOnFirstError: false,
            KeepIntermediateFiles: false,
            SummaryFilePath: "summary.txt");

        var files = FileDiscoveryService.DiscoverInputFiles(options);

        Assert.Equal(3, files.Count);
        Assert.Contains("alpha.m4a", files[0].InputPath);
        Assert.Contains("bravo.m4a", files[1].InputPath);
        Assert.Contains("charlie.m4a", files[2].InputPath);
        Assert.All(files, f => Assert.Equal(DiscoveryStatus.Ready, f.Status));
    }

    [Fact]
    public void DiscoverInputFiles_NoMatchingFiles_Throws()
    {
        using var directory = new TemporaryDirectory();
        var inputDir = Path.Combine(directory.Path, "input");
        Directory.CreateDirectory(inputDir);

        File.WriteAllText(Path.Combine(inputDir, "readme.txt"), "not audio");

        var options = new BatchOptions(
            InputDirectory: inputDir,
            OutputDirectory: directory.Path,
            TempDirectory: directory.Path,
            FilePattern: "*.m4a",
            StopOnFirstError: false,
            KeepIntermediateFiles: false,
            SummaryFilePath: "summary.txt");

        var exception = Assert.Throws<InvalidOperationException>(() => FileDiscoveryService.DiscoverInputFiles(options));
        Assert.Contains("No files matching", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void DiscoverInputFiles_EmptyFilesAreSkipped()
    {
        using var directory = new TemporaryDirectory();
        var inputDir = Path.Combine(directory.Path, "input");
        var outputDir = Path.Combine(directory.Path, "output");
        Directory.CreateDirectory(inputDir);
        Directory.CreateDirectory(outputDir);

        File.WriteAllText(Path.Combine(inputDir, "good.m4a"), "audio data");
        File.WriteAllText(Path.Combine(inputDir, "empty.m4a"), "");

        var options = new BatchOptions(
            InputDirectory: inputDir,
            OutputDirectory: outputDir,
            TempDirectory: directory.Path,
            FilePattern: "*.m4a",
            StopOnFirstError: false,
            KeepIntermediateFiles: false,
            SummaryFilePath: "summary.txt");

        var files = FileDiscoveryService.DiscoverInputFiles(options);

        Assert.Equal(2, files.Count);
        var emptyFile = files.First(f => Path.GetFileName(f.InputPath) == "empty.m4a");
        var goodFile = files.First(f => Path.GetFileName(f.InputPath) == "good.m4a");
        Assert.Equal(DiscoveryStatus.Skipped, emptyFile.Status);
        Assert.Equal(DiscoveryStatus.Ready, goodFile.Status);
    }

    [Fact]
    public void DiscoverInputFiles_OutputAndTempPathsAreGeneratedCorrectly()
    {
        using var directory = new TemporaryDirectory();
        var inputDir = Path.Combine(directory.Path, "input");
        var outputDir = Path.Combine(directory.Path, "output");
        var tempDir = Path.Combine(directory.Path, "temp");
        Directory.CreateDirectory(inputDir);
        Directory.CreateDirectory(outputDir);
        Directory.CreateDirectory(tempDir);

        File.WriteAllText(Path.Combine(inputDir, "recording.m4a"), "audio data");

        var options = new BatchOptions(
            InputDirectory: inputDir,
            OutputDirectory: outputDir,
            TempDirectory: tempDir,
            FilePattern: "*.m4a",
            StopOnFirstError: false,
            KeepIntermediateFiles: false,
            SummaryFilePath: "summary.txt");

        var files = FileDiscoveryService.DiscoverInputFiles(options);

        Assert.Single(files);
        Assert.Equal(Path.Combine(outputDir, "recording.txt"), files[0].OutputPath);
        Assert.StartsWith(tempDir, files[0].TempWavPath);
        Assert.EndsWith(".wav", files[0].TempWavPath);
    }

    [Fact]
    public void DiscoverInputFiles_CustomFilePattern_FiltersCorrectly()
    {
        using var directory = new TemporaryDirectory();
        var inputDir = Path.Combine(directory.Path, "input");
        Directory.CreateDirectory(inputDir);

        File.WriteAllText(Path.Combine(inputDir, "audio.m4a"), "m4a data");
        File.WriteAllText(Path.Combine(inputDir, "audio.wav"), "wav data");
        File.WriteAllText(Path.Combine(inputDir, "audio.mp3"), "mp3 data");

        var options = new BatchOptions(
            InputDirectory: inputDir,
            OutputDirectory: directory.Path,
            TempDirectory: directory.Path,
            FilePattern: "*.wav",
            StopOnFirstError: false,
            KeepIntermediateFiles: false,
            SummaryFilePath: "summary.txt");

        var files = FileDiscoveryService.DiscoverInputFiles(options);

        Assert.Single(files);
        Assert.Contains("audio.wav", files[0].InputPath);
    }

    [Fact]
    public void DiscoverInputFiles_MissingDirectory_Throws()
    {
        var options = new BatchOptions(
            InputDirectory: Path.Combine(Path.GetTempPath(), $"missing-{Guid.NewGuid():N}"),
            OutputDirectory: Path.GetTempPath(),
            TempDirectory: Path.GetTempPath(),
            FilePattern: "*.m4a",
            StopOnFirstError: false,
            KeepIntermediateFiles: false,
            SummaryFilePath: "summary.txt");

        var exception = Assert.Throws<InvalidOperationException>(() => FileDiscoveryService.DiscoverInputFiles(options));
        Assert.Contains("not found", exception.Message, StringComparison.OrdinalIgnoreCase);
    }
}
