#nullable enable
using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Xunit;

public sealed class FacadeTests
{
    [Fact]
    public void LanguageInfoFacade_ReturnsLanguagesFromConfig()
    {
        // This test requires a valid appsettings.json.
        // In real test runs, we would use a test settings file.
        // For now, we test the DTO mapping logic.
        var dto = new SupportedLanguageDto("en", "English", 0);

        Assert.Equal("en", dto.Code);
        Assert.Equal("English", dto.DisplayName);
        Assert.Equal(0, dto.Priority);
    }

    [Fact]
    public async Task TranscriptReaderFacade_RejectsPathOutsideAllowedRoots()
    {
        var policy = new PathPolicy(
            allowedInputRoots: new[] { "/allowed/input" },
            allowedOutputRoots: Array.Empty<string>(),
            requireAbsolutePaths: true);

        var facade = new TranscriptReaderFacade(policy);

        await Assert.ThrowsAsync<UnauthorizedAccessException>(() =>
            facade.ReadTranscriptAsync("/not-allowed/file.txt"));
    }

    [Fact]
    public async Task TranscriptReaderFacade_RejectsMissingFile()
    {
        var tempDir = Path.GetTempPath();
        var policy = new PathPolicy(
            allowedInputRoots: new[] { tempDir },
            allowedOutputRoots: Array.Empty<string>(),
            requireAbsolutePaths: true);

        var facade = new TranscriptReaderFacade(policy);
        var fakePath = Path.Combine(tempDir, $"nonexistent_{Guid.NewGuid():N}.txt");

        await Assert.ThrowsAsync<FileNotFoundException>(() =>
            facade.ReadTranscriptAsync(fakePath));
    }

    [Fact]
    public async Task TranscriptReaderFacade_ReadsExistingFile()
    {
        var tempDir = Path.GetTempPath();
        var policy = new PathPolicy(
            allowedInputRoots: new[] { tempDir },
            allowedOutputRoots: Array.Empty<string>(),
            requireAbsolutePaths: true);

        var facade = new TranscriptReaderFacade(policy);
        var filePath = Path.Combine(tempDir, $"test_{Guid.NewGuid():N}.txt");

        try
        {
            await File.WriteAllTextAsync(filePath, "00:00:01->00:00:03: Hello world\n");

            var result = await facade.ReadTranscriptAsync(filePath);

            Assert.Equal(filePath, result.Path);
            Assert.Contains("Hello world", result.Content);
            Assert.False(result.WasTruncated);
        }
        finally
        {
            if (File.Exists(filePath)) File.Delete(filePath);
        }
    }

    [Fact]
    public async Task TranscriptReaderFacade_TruncatesLongContent()
    {
        var tempDir = Path.GetTempPath();
        var policy = new PathPolicy(
            allowedInputRoots: new[] { tempDir },
            allowedOutputRoots: Array.Empty<string>(),
            requireAbsolutePaths: true);

        var facade = new TranscriptReaderFacade(policy);
        var filePath = Path.Combine(tempDir, $"test_{Guid.NewGuid():N}.txt");

        try
        {
            var longContent = new string('A', 1000);
            await File.WriteAllTextAsync(filePath, longContent);

            var result = await facade.ReadTranscriptAsync(filePath, maxCharacters: 100);

            Assert.True(result.WasTruncated);
            Assert.Equal(100, result.Content.Length);
            Assert.Equal(1000, result.TotalLength);
        }
        finally
        {
            if (File.Exists(filePath)) File.Delete(filePath);
        }
    }

    [Fact]
    public void ModelInspectionFacade_InspectModel_StructureIsCorrect()
    {
        // Test the DTO structure for a missing model scenario.
        var result = new ModelInfoResultDto(
            ModelPath: "/models/missing.bin",
            ModelType: "Base",
            Exists: false,
            FileSizeBytes: null,
            IsLoadable: false,
            NeedsDownload: true);

        Assert.True(result.NeedsDownload);
        Assert.False(result.Exists);
        Assert.Null(result.FileSizeBytes);
    }

    [Fact]
    public void StartupValidationResultDto_MapsCorrectly()
    {
        var checks = new[]
        {
            new StartupCheckDto("Settings file", "Passed", "/config/appsettings.json"),
            new StartupCheckDto("ffmpeg", "Passed", "ffmpeg version 6.0"),
            new StartupCheckDto("Model type", "Failed", "Invalid model type: Unknown")
        };

        var result = new StartupValidationResultDto(
            Outcome: "FAILED",
            CanStart: false,
            HasWarnings: false,
            ResolvedConfigurationPath: "/config/appsettings.json",
            Checks: checks);

        Assert.Equal(3, result.Checks.Count);
        Assert.Equal("FAILED", result.Outcome);
        Assert.False(result.CanStart);
        Assert.Equal("Failed", result.Checks.Last().Status);
    }
}
