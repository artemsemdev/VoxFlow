using System;
using System.IO;
using Xunit;

public sealed class TranscriptionOptionsTests
{
    [Fact]
    public void LoadFromPath_ParsesConfiguredValues()
    {
        using var directory = new TemporaryDirectory();

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "/usr/local/bin/ffmpeg",
            supportedLanguages: [("en", "English"), ("uk", "Ukrainian")]);

        var options = TranscriptionOptions.LoadFromPath(settingsPath);

        Assert.Equal(settingsPath, options.ConfigurationPath);
        Assert.Equal("/tmp/input.m4a", options.InputFilePath);
        Assert.Equal("/usr/local/bin/ffmpeg", options.FfmpegExecutablePath);
        Assert.Equal(2, options.AudioFilterChain.Count);
        Assert.Equal("afftdn=nf=-25", options.AudioFilterChain[0]);
        Assert.Equal(2, options.SupportedLanguages.Count);
        Assert.Equal("English, Ukrainian", options.GetSupportedLanguageSummary());
        Assert.True(options.StartupValidation.Enabled);
        Assert.True(options.UseNoContext);
        Assert.Equal(0.75f, options.NoSpeechThreshold);
        Assert.Equal(-0.8f, options.LogProbThreshold);
        Assert.True(options.SuppressBracketedNonSpeechSegments);
    }

    [Fact]
    public void LoadFromPath_RejectsDuplicateLanguageCodes()
    {
        using var directory = new TemporaryDirectory();

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg",
            supportedLanguages: [("en", "English"), ("EN", "English Duplicate")]);

        var exception = Assert.Throws<InvalidOperationException>(() => TranscriptionOptions.LoadFromPath(settingsPath));
        Assert.Contains("unique", exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void LoadFromPath_ThrowsWhenFileDoesNotExist()
    {
        var missingPath = Path.Combine(Path.GetTempPath(), $"missing-{Guid.NewGuid():N}.json");
        Assert.Throws<FileNotFoundException>(() => TranscriptionOptions.LoadFromPath(missingPath));
    }

    [Fact]
    public void LoadFromPath_AssignsTieBreakPrioritiesByConfigurationOrder()
    {
        using var directory = new TemporaryDirectory();

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg",
            supportedLanguages: [("en", "English"), ("de", "German"), ("uk", "Ukrainian")]);

        var options = TranscriptionOptions.LoadFromPath(settingsPath);

        Assert.Equal(0, options.SupportedLanguages[0].Priority);
        Assert.Equal(1, options.SupportedLanguages[1].Priority);
        Assert.Equal(2, options.SupportedLanguages[2].Priority);
    }

    [Fact]
    public void LoadFromPath_ParsesAntiHallucinationSettings()
    {
        using var directory = new TemporaryDirectory();

        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg",
            entropyThreshold: 2.4f,
            maxConsecutiveDuplicateSegments: 3,
            maxDuplicateSegmentTextLength: 64);

        var options = TranscriptionOptions.LoadFromPath(settingsPath);

        Assert.Equal(2.4f, options.EntropyThreshold);
        Assert.Equal(3, options.MaxConsecutiveDuplicateSegments);
        Assert.Equal(64, options.MaxDuplicateSegmentTextLength);
    }
}
