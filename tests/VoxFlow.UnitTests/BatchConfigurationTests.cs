using System;
using System.IO;
using Xunit;

public sealed class BatchConfigurationTests
{
    [Fact]
    public void LoadFromPath_SingleMode_BatchIsDisabled()
    {
        using var directory = new TemporaryDirectory();

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg");

        var options = TranscriptionOptions.LoadFromPath(settingsPath);

        Assert.False(options.IsBatchMode);
    }

    [Fact]
    public void LoadFromPath_ExplicitSingleMode_BatchIsDisabled()
    {
        using var directory = new TemporaryDirectory();

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg",
            processingMode: "single");

        var options = TranscriptionOptions.LoadFromPath(settingsPath);

        Assert.False(options.IsBatchMode);
    }

    [Fact]
    public void LoadFromPath_BatchModeWithoutInputDirectory_Throws()
    {
        using var directory = new TemporaryDirectory();

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg",
            processingMode: "batch",
            batch: new
            {
                inputDirectory = "",
                outputDirectory = "/tmp/output"
            });

        var exception = Assert.Throws<InvalidOperationException>(() => TranscriptionOptions.LoadFromPath(settingsPath));
        Assert.Contains("InputDirectory", exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void LoadFromPath_BatchModeWithoutOutputDirectory_Throws()
    {
        using var directory = new TemporaryDirectory();

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg",
            processingMode: "batch",
            batch: new
            {
                inputDirectory = "/tmp/input",
                outputDirectory = ""
            });

        var exception = Assert.Throws<InvalidOperationException>(() => TranscriptionOptions.LoadFromPath(settingsPath));
        Assert.Contains("OutputDirectory", exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void LoadFromPath_ValidBatchConfig_AllOptionsPopulated()
    {
        using var directory = new TemporaryDirectory();

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg",
            processingMode: "batch",
            batch: new
            {
                inputDirectory = "/tmp/batch-input",
                outputDirectory = "/tmp/batch-output",
                tempDirectory = "/tmp/batch-temp",
                filePattern = "*.wav",
                stopOnFirstError = true,
                keepIntermediateFiles = true,
                summaryFilePath = "/tmp/summary.txt"
            });

        var options = TranscriptionOptions.LoadFromPath(settingsPath);

        Assert.True(options.IsBatchMode);
        Assert.Equal("/tmp/batch-input", options.Batch.InputDirectory);
        Assert.Equal("/tmp/batch-output", options.Batch.OutputDirectory);
        Assert.Equal("/tmp/batch-temp", options.Batch.TempDirectory);
        Assert.Equal("*.wav", options.Batch.FilePattern);
        Assert.True(options.Batch.StopOnFirstError);
        Assert.True(options.Batch.KeepIntermediateFiles);
        Assert.Equal("/tmp/summary.txt", options.Batch.SummaryFilePath);
    }

    [Fact]
    public void LoadFromPath_BatchWithDefaults_AppliesDefaultValues()
    {
        using var directory = new TemporaryDirectory();

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg",
            processingMode: "batch",
            batch: new
            {
                inputDirectory = "/tmp/batch-input",
                outputDirectory = "/tmp/batch-output"
            });

        var options = TranscriptionOptions.LoadFromPath(settingsPath);

        Assert.True(options.IsBatchMode);
        Assert.Equal("*.m4a", options.Batch.FilePattern);
        Assert.False(options.Batch.StopOnFirstError);
        Assert.False(options.Batch.KeepIntermediateFiles);
        Assert.Equal("batch-summary.txt", options.Batch.SummaryFilePath);
        Assert.False(string.IsNullOrWhiteSpace(options.Batch.TempDirectory));
    }

    [Fact]
    public void LoadFromPath_BatchModeWithoutBatchSection_Throws()
    {
        using var directory = new TemporaryDirectory();

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg",
            processingMode: "batch");

        var exception = Assert.Throws<InvalidOperationException>(() => TranscriptionOptions.LoadFromPath(settingsPath));
        Assert.Contains("batch", exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void LoadFromPath_BatchModeSingleFilePathsOptional()
    {
        using var directory = new TemporaryDirectory();

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "",
            wavFilePath: "",
            resultFilePath: "",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg",
            processingMode: "batch",
            batch: new
            {
                inputDirectory = "/tmp/batch-input",
                outputDirectory = "/tmp/batch-output"
            });

        var options = TranscriptionOptions.LoadFromPath(settingsPath);

        Assert.True(options.IsBatchMode);
        Assert.Equal(string.Empty, options.InputFilePath);
        Assert.Equal(string.Empty, options.WavFilePath);
        Assert.Equal(string.Empty, options.ResultFilePath);
    }
}
