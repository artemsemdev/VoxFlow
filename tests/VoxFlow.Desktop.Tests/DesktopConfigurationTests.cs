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

    [Fact]
    public void ResolveBundledConfigPath_PrefersBaseDirectoryFile()
    {
        var baseDirectory = Path.Combine(_tempDir, "base");
        Directory.CreateDirectory(baseDirectory);
        var expectedPath = Path.Combine(baseDirectory, "appsettings.json");
        File.WriteAllText(expectedPath, "{}");

        var resolvedPath = DesktopConfigurationService.ResolveBundledConfigPath(baseDirectory);

        Assert.Equal(expectedPath, resolvedPath);
    }

    [Fact]
    public void ResolveBundledConfigPath_FindsMacCatalystResourcesFile()
    {
        var monoBundleDirectory = Path.Combine(_tempDir, "VoxFlow.Desktop.app", "Contents", "MonoBundle");
        var resourcesDirectory = Path.Combine(_tempDir, "VoxFlow.Desktop.app", "Contents", "Resources");
        Directory.CreateDirectory(monoBundleDirectory);
        Directory.CreateDirectory(resourcesDirectory);

        var expectedPath = Path.Combine(resourcesDirectory, "appsettings.json");
        File.WriteAllText(expectedPath, "{}");

        var resolvedPath = DesktopConfigurationService.ResolveBundledConfigPath(monoBundleDirectory);

        Assert.Equal(expectedPath, resolvedPath);
    }

    [Fact]
    public void ResolveDesktopPath_ExpandsHomeDirectory()
    {
        var expectedPath = Path.GetFullPath(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Library/Application Support/VoxFlow/models/ggml-base.bin"));

        var resolvedPath = DesktopConfigurationService.ResolveDesktopPath(
            "~/Library/Application Support/VoxFlow/models/ggml-base.bin",
            _tempDir,
            "ignored.bin");

        Assert.Equal(expectedPath, resolvedPath);
    }

    [Fact]
    public void NormalizeDesktopConfiguration_ResolvesDesktopPathsAndCreatesDirectories()
    {
        var appSupportDir = Path.Combine(_tempDir, "app-support");
        var documentsDir = Path.Combine(_tempDir, "documents");

        var json = JsonSerializer.Serialize(new
        {
            transcription = new
            {
                wavFilePath = "artifacts/output.wav",
                resultFilePath = "result.txt",
                modelFilePath = "models/ggml-base.bin",
                batch = new
                {
                    outputDirectory = "output",
                    tempDirectory = "temp",
                    summaryFilePath = "reports/batch-summary.txt"
                }
            }
        });

        var normalized = DesktopConfigurationService.NormalizeDesktopConfiguration(json, appSupportDir, documentsDir);

        using var doc = JsonDocument.Parse(normalized);
        var transcription = doc.RootElement.GetProperty("transcription");

        Assert.Equal(
            Path.GetFullPath(Path.Combine(appSupportDir, "artifacts/output.wav")),
            transcription.GetProperty("wavFilePath").GetString());
        Assert.Equal(
            Path.GetFullPath(Path.Combine(documentsDir, "result.txt")),
            transcription.GetProperty("resultFilePath").GetString());
        Assert.Equal(
            Path.GetFullPath(Path.Combine(appSupportDir, "models/ggml-base.bin")),
            transcription.GetProperty("modelFilePath").GetString());

        var batch = transcription.GetProperty("batch");
        Assert.Equal(
            Path.GetFullPath(Path.Combine(documentsDir, "output")),
            batch.GetProperty("outputDirectory").GetString());
        Assert.Equal(
            Path.GetFullPath(Path.Combine(appSupportDir, "temp")),
            batch.GetProperty("tempDirectory").GetString());
        Assert.Equal(
            Path.GetFullPath(Path.Combine(documentsDir, "reports/batch-summary.txt")),
            batch.GetProperty("summaryFilePath").GetString());

        Assert.True(Directory.Exists(Path.Combine(appSupportDir, "artifacts")));
        Assert.True(Directory.Exists(documentsDir));
        Assert.True(Directory.Exists(Path.Combine(appSupportDir, "models")));
        Assert.True(Directory.Exists(Path.Combine(documentsDir, "output")));
        Assert.True(Directory.Exists(Path.Combine(appSupportDir, "temp")));
        Assert.True(Directory.Exists(Path.Combine(documentsDir, "reports")));
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
