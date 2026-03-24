#nullable enable
using System;
using System.Collections.Generic;
using VoxFlow.Core.Models;
using Xunit;

/// <summary>
/// Verifies that Core model types used by the MCP server have the expected structure.
/// These replace the old ApplicationContractTests that tested facade DTOs.
/// </summary>
public sealed class CoreModelIntegrationTests
{
    [Fact]
    public void ValidationResult_CanBeCreated()
    {
        var checks = new List<ValidationCheck>
        {
            new("Settings file", ValidationCheckStatus.Passed, "/path/to/settings.json"),
            new("ffmpeg", ValidationCheckStatus.Failed, "ffmpeg not found")
        };

        var result = new ValidationResult(
            Outcome: "FAILED",
            CanStart: false,
            HasWarnings: false,
            ResolvedConfigurationPath: "/path/to/settings.json",
            Checks: checks);

        Assert.Equal("FAILED", result.Outcome);
        Assert.False(result.CanStart);
        Assert.Equal(2, result.Checks.Count);
    }

    [Fact]
    public void TranscribeFileResult_SuccessResult()
    {
        var result = new TranscribeFileResult(
            Success: true,
            DetectedLanguage: "English (en)",
            ResultFilePath: "/output/result.txt",
            AcceptedSegmentCount: 42,
            SkippedSegmentCount: 3,
            Duration: TimeSpan.FromSeconds(15),
            Warnings: Array.Empty<string>(),
            TranscriptPreview: "00:00:01->00:00:03: Hello world");

        Assert.True(result.Success);
        Assert.Equal("English (en)", result.DetectedLanguage);
        Assert.Equal(42, result.AcceptedSegmentCount);
        Assert.Empty(result.Warnings);
    }

    [Fact]
    public void TranscribeFileResult_FailureResult()
    {
        var result = new TranscribeFileResult(
            Success: false,
            DetectedLanguage: null,
            ResultFilePath: null,
            AcceptedSegmentCount: 0,
            SkippedSegmentCount: 0,
            Duration: TimeSpan.FromMilliseconds(50),
            Warnings: new[] { "Input file not found." },
            TranscriptPreview: null);

        Assert.False(result.Success);
        Assert.Null(result.DetectedLanguage);
        Assert.Single(result.Warnings);
    }

    [Fact]
    public void BatchTranscribeResult_CanBeCreated()
    {
        var fileResults = new List<BatchFileResult>
        {
            new("/input/a.m4a", "/output/a.txt", "Success", null, TimeSpan.FromSeconds(10), "English (en)"),
            new("/input/b.m4a", "/output/b.txt", "Failed", "Corrupt header", TimeSpan.FromSeconds(1), null),
            new("/input/c.m4a", "/output/c.txt", "Skipped", "File is empty", TimeSpan.Zero, null)
        };

        var result = new BatchTranscribeResult(
            TotalFiles: 3,
            Succeeded: 1,
            Failed: 1,
            Skipped: 1,
            SummaryFilePath: "/output/summary.txt",
            TotalDuration: TimeSpan.FromSeconds(11),
            Results: fileResults);

        Assert.Equal(3, result.TotalFiles);
        Assert.Equal(1, result.Succeeded);
        Assert.Equal(1, result.Failed);
        Assert.Equal(1, result.Skipped);
    }

    [Fact]
    public void ModelInfo_ModelReady()
    {
        var result = new ModelInfo(
            ModelPath: "/models/ggml-base.bin",
            ModelType: "Base",
            Exists: true,
            FileSizeBytes: 142_000_000,
            IsLoadable: true,
            NeedsDownload: false);

        Assert.True(result.Exists);
        Assert.True(result.IsLoadable);
        Assert.False(result.NeedsDownload);
    }

    [Fact]
    public void ModelInfo_ModelMissing()
    {
        var result = new ModelInfo(
            ModelPath: "/models/ggml-base.bin",
            ModelType: "Base",
            Exists: false,
            FileSizeBytes: null,
            IsLoadable: false,
            NeedsDownload: true);

        Assert.False(result.Exists);
        Assert.False(result.IsLoadable);
        Assert.True(result.NeedsDownload);
    }

    [Fact]
    public void SupportedLanguage_CanBeCreated()
    {
        var language = new SupportedLanguage("en", "English", 0);

        Assert.Equal("en", language.Code);
        Assert.Equal("English", language.DisplayName);
        Assert.Equal(0, language.Priority);
    }

    [Fact]
    public void TranscriptReadResult_FullContent()
    {
        var result = new TranscriptReadResult(
            Path: "/output/result.txt",
            Content: "00:00:01->00:00:03: Hello",
            TotalLength: 25,
            WasTruncated: false);

        Assert.False(result.WasTruncated);
        Assert.Equal(25, result.TotalLength);
    }

    [Fact]
    public void TranscriptReadResult_TruncatedContent()
    {
        var result = new TranscriptReadResult(
            Path: "/output/result.txt",
            Content: "00:00:01->",
            TotalLength: 500,
            WasTruncated: true);

        Assert.True(result.WasTruncated);
        Assert.Equal(500, result.TotalLength);
    }

    [Fact]
    public void TranscribeFileRequest_DefaultValues()
    {
        var request = new TranscribeFileRequest("/input/test.m4a");

        Assert.Equal("/input/test.m4a", request.InputPath);
        Assert.Null(request.ResultFilePath);
        Assert.Null(request.ConfigurationPath);
        Assert.Null(request.ForceLanguages);
        Assert.True(request.OverwriteExistingResult);
    }

    [Fact]
    public void BatchTranscribeRequest_DefaultValues()
    {
        var request = new BatchTranscribeRequest("/input", "/output");

        Assert.Equal("/input", request.InputDirectory);
        Assert.Equal("/output", request.OutputDirectory);
        Assert.Null(request.FilePattern);
        Assert.Null(request.SummaryFilePath);
        Assert.False(request.StopOnFirstError);
        Assert.False(request.KeepIntermediateFiles);
        Assert.Null(request.ConfigurationPath);
        Assert.Null(request.MaxFiles);
    }
}
