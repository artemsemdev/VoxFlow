using System.Text.Json;
using VoxFlow.Desktop.Configuration;
using Xunit;

namespace VoxFlow.Desktop.Tests;

public sealed class DesktopConfigurationTests : IDisposable
{
    private readonly string _tempDir;

    public DesktopConfigurationTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"voxflow-cfg-test-{Guid.NewGuid()}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_tempDir, recursive: true); } catch { /* best-effort */ }
    }

    /// <summary>
    /// Writes the given object as JSON to a file in the temp directory.
    /// Returns the full path to the written file.
    /// </summary>
    private string WriteJsonFile(string fileName, object content)
    {
        var path = Path.Combine(_tempDir, fileName);
        var json = JsonSerializer.Serialize(content, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json);
        return path;
    }

    // -----------------------------------------------------------------------
    // MergeJsonFiles — user overrides replace specified values, bundled
    // defaults remain for unspecified values
    // -----------------------------------------------------------------------

    [Fact]
    public void MergeJsonFiles_UserOverridesReplaceSpecifiedValues()
    {
        var basePath = WriteJsonFile("base.json", new
        {
            transcription = new
            {
                modelType = "Base",
                outputSampleRate = 16000,
                outputChannelCount = 1
            }
        });

        var userPath = WriteJsonFile("user.json", new
        {
            transcription = new
            {
                modelType = "Large"
            }
        });

        var result = DesktopConfigurationService.MergeJsonFiles(basePath, userPath, overridePath: null);
        using var doc = JsonDocument.Parse(result);
        var transcription = doc.RootElement.GetProperty("transcription");

        // User override replaced modelType
        Assert.Equal("Large", transcription.GetProperty("modelType").GetString());
        // Bundled defaults remain for the others
        Assert.Equal(16000, transcription.GetProperty("outputSampleRate").GetInt32());
        Assert.Equal(1, transcription.GetProperty("outputChannelCount").GetInt32());
    }

    // -----------------------------------------------------------------------
    // MergeJsonFiles — missing user config file uses bundled defaults only
    // -----------------------------------------------------------------------

    [Fact]
    public void MergeJsonFiles_MissingUserConfig_UsesBundledDefaultsOnly()
    {
        var basePath = WriteJsonFile("base.json", new
        {
            transcription = new
            {
                modelType = "Base",
                outputSampleRate = 16000
            }
        });

        var nonExistentUserPath = Path.Combine(_tempDir, "does-not-exist.json");

        var result = DesktopConfigurationService.MergeJsonFiles(basePath, nonExistentUserPath, overridePath: null);
        using var doc = JsonDocument.Parse(result);
        var transcription = doc.RootElement.GetProperty("transcription");

        Assert.Equal("Base", transcription.GetProperty("modelType").GetString());
        Assert.Equal(16000, transcription.GetProperty("outputSampleRate").GetInt32());
    }

    // -----------------------------------------------------------------------
    // MergeJsonFiles — three-layer merge: base, user, and override
    // -----------------------------------------------------------------------

    [Fact]
    public void MergeJsonFiles_ThreeLayers_OverrideWins()
    {
        var basePath = WriteJsonFile("base.json", new
        {
            transcription = new
            {
                modelType = "Base",
                outputSampleRate = 16000,
                outputChannelCount = 1
            }
        });

        var userPath = WriteJsonFile("user.json", new
        {
            transcription = new
            {
                modelType = "Large"
            }
        });

        var overridePath = WriteJsonFile("override.json", new
        {
            transcription = new
            {
                modelType = "Turbo",
                outputChannelCount = 2
            }
        });

        var result = DesktopConfigurationService.MergeJsonFiles(basePath, userPath, overridePath);
        using var doc = JsonDocument.Parse(result);
        var transcription = doc.RootElement.GetProperty("transcription");

        // Override layer wins for modelType and outputChannelCount
        Assert.Equal("Turbo", transcription.GetProperty("modelType").GetString());
        Assert.Equal(2, transcription.GetProperty("outputChannelCount").GetInt32());
        // Base default remains for outputSampleRate (not overridden by user or override)
        Assert.Equal(16000, transcription.GetProperty("outputSampleRate").GetInt32());
    }

    // -----------------------------------------------------------------------
    // MergeJsonFiles — missing base config produces empty object (no crash)
    // -----------------------------------------------------------------------

    [Fact]
    public void MergeJsonFiles_MissingBaseConfig_DoesNotThrow()
    {
        var nonExistentBase = Path.Combine(_tempDir, "no-base.json");
        var userPath = WriteJsonFile("user.json", new
        {
            transcription = new
            {
                modelType = "Large"
            }
        });

        var result = DesktopConfigurationService.MergeJsonFiles(nonExistentBase, userPath, overridePath: null);
        using var doc = JsonDocument.Parse(result);
        var transcription = doc.RootElement.GetProperty("transcription");

        Assert.Equal("Large", transcription.GetProperty("modelType").GetString());
    }

    // -----------------------------------------------------------------------
    // MergeJsonFiles — deep merge of nested objects
    // -----------------------------------------------------------------------

    [Fact]
    public void MergeJsonFiles_DeepMergesNestedObjects()
    {
        var basePath = WriteJsonFile("base.json", new
        {
            transcription = new
            {
                startupValidation = new
                {
                    enabled = true,
                    checkInputFile = true,
                    checkModelDirectory = true
                }
            }
        });

        var userPath = WriteJsonFile("user.json", new
        {
            transcription = new
            {
                startupValidation = new
                {
                    checkInputFile = false
                }
            }
        });

        var result = DesktopConfigurationService.MergeJsonFiles(basePath, userPath, overridePath: null);
        using var doc = JsonDocument.Parse(result);
        var validation = doc.RootElement
            .GetProperty("transcription")
            .GetProperty("startupValidation");

        // User override changed checkInputFile
        Assert.False(validation.GetProperty("checkInputFile").GetBoolean());
        // Base defaults remain
        Assert.True(validation.GetProperty("enabled").GetBoolean());
        Assert.True(validation.GetProperty("checkModelDirectory").GetBoolean());
    }
}
