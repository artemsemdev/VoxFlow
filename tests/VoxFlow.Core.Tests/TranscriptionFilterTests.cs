using System;
using System.IO;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Models;
using VoxFlow.Core.Services;
using Whisper.net;
using Xunit;

namespace VoxFlow.Core.Tests;

public sealed class TranscriptionFilterTests
{
    [Fact]
    public void FilterSegments_SkipsNoiseAndLowValueSegments()
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
        var language = new SupportedLanguage("en", "English", 0);
        var filter = new TranscriptionFilter();

        var segments = new[]
        {
            CreateSegment("   ", 0.90f, 1),
            CreateSegment("[music]", 0.90f, 1),
            CreateSegment("[door opening]", 0.90f, 1),
            CreateSegment("hi", 0.10f, 1),
            CreateSegment("...", 0.90f, 1),
            CreateSegment("tiny", 0.90f, 31),
            CreateSegment("Repeated phrase.", 0.90f, 2),
            CreateSegment("Repeated phrase.", 0.90f, 2),
            CreateSegment("Repeated phrase.", 0.90f, 2),
            CreateSegment("  valid   speech  ", 0.90f, 3)
        };

        var result = filter.FilterSegments(language, segments, options);

        Assert.Equal(3, result.Accepted.Count);
        Assert.Equal("Repeated phrase.", result.Accepted[0].Text);
        Assert.Equal("Repeated phrase.", result.Accepted[1].Text);
        Assert.Equal("valid speech", result.Accepted[2].Text);
        Assert.Equal(7, result.Skipped.Count);
        Assert.Contains(result.Skipped, segment => segment.Reason == SegmentSkipReason.EmptyText);
        Assert.Contains(result.Skipped, segment => segment.Reason == SegmentSkipReason.NoiseMarker);
        Assert.Contains(result.Skipped, segment => segment.Reason == SegmentSkipReason.LowProbability);
        Assert.Contains(result.Skipped, segment => segment.Reason == SegmentSkipReason.SuspiciousNonSpeech);
        Assert.Contains(result.Skipped, segment => segment.Reason == SegmentSkipReason.LowInformationLong);
        Assert.Contains(result.Skipped, segment => segment.Reason == SegmentSkipReason.RepetitiveLoop);
    }

    [Fact]
    public void FilterSegments_AcceptsAllValidSegments_WhenNoFilterTriggered()
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
        var language = new SupportedLanguage("en", "English", 0);
        var filter = new TranscriptionFilter();

        var segments = new[]
        {
            CreateSegment("Hello world", 0.95f, 2),
            CreateSegment("This is a test", 0.88f, 3),
            CreateSegment("Goodbye", 0.72f, 1)
        };

        var result = filter.FilterSegments(language, segments, options);

        Assert.Equal(3, result.Accepted.Count);
        Assert.Empty(result.Skipped);
    }

    [Fact]
    public void FilterSegments_SkipsBracketedNonSpeechPlaceholders()
    {
        using var directory = new TemporaryDirectory();
        var settingsPath = TestSettingsFileFactory.Write(
            directory.Path,
            inputFilePath: "/tmp/input.m4a",
            wavFilePath: "/tmp/output.wav",
            resultFilePath: "/tmp/result.txt",
            modelFilePath: "/tmp/model.bin",
            ffmpegExecutablePath: "ffmpeg",
            suppressBracketedNonSpeechSegments: true);

        var options = TranscriptionOptions.LoadFromPath(settingsPath);
        var language = new SupportedLanguage("en", "English", 0);
        var filter = new TranscriptionFilter();

        var segments = new[]
        {
            CreateSegment("[door opening]", 0.90f, 1),
            CreateSegment("(clapping)", 0.90f, 1),
            CreateSegment("[This is a real sentence.]", 0.90f, 1),
            CreateSegment("Normal speech", 0.90f, 2)
        };

        var result = filter.FilterSegments(language, segments, options);

        Assert.Equal(2, result.Accepted.Count);
        Assert.Equal("[This is a real sentence.]", result.Accepted[0].Text);
        Assert.Equal("Normal speech", result.Accepted[1].Text);
    }

    [Fact]
    public void FilterSegments_NormalizesWhitespaceInAcceptedSegments()
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
        var language = new SupportedLanguage("en", "English", 0);
        var filter = new TranscriptionFilter();

        var segments = new[]
        {
            CreateSegment("  multiple   spaces   here  ", 0.90f, 2),
            CreateSegment("\ttabs\tand\tnewlines\n", 0.90f, 2)
        };

        var result = filter.FilterSegments(language, segments, options);

        Assert.Equal(2, result.Accepted.Count);
        Assert.Equal("multiple spaces here", result.Accepted[0].Text);
        Assert.Equal("tabs and newlines", result.Accepted[1].Text);
    }

    [Fact]
    public void FilterSegments_ReturnsEmptyForEmptyInput()
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
        var language = new SupportedLanguage("en", "English", 0);
        var filter = new TranscriptionFilter();

        var result = filter.FilterSegments(language, Array.Empty<SegmentData>(), options);

        Assert.Empty(result.Accepted);
        Assert.Empty(result.Skipped);
    }

    private static SegmentData CreateSegment(string text, float probability, int durationSeconds)
    {
        return new SegmentData(
            text,
            TimeSpan.Zero,
            TimeSpan.FromSeconds(durationSeconds),
            probability,
            probability,
            probability,
            probability,
            "en",
            Array.Empty<WhisperToken>());
    }
}
