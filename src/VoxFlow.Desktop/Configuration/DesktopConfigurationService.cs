using System.Text.Json;
using System.Text.Json.Nodes;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using VoxFlow.Desktop.Services;

namespace VoxFlow.Desktop.Configuration;

public sealed class DesktopConfigurationService : IConfigurationService
{
    private static readonly string AppSupportDir =
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Library",
            "Application Support",
            "VoxFlow");

    private static readonly string UserConfigPath =
        Path.Combine(AppSupportDir, "appsettings.json");

    private static readonly string DocumentsDir =
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            "VoxFlow");

    public Task<TranscriptionOptions> LoadAsync(string? configurationPath = null)
    {
        var tempPath = WriteMergedConfigurationSnapshot(configurationPath, applyDesktopRuntimeOverrides: true);
        try
        {
            var options = TranscriptionOptions.LoadFromPath(tempPath);
            return Task.FromResult(options);
        }
        finally
        {
            try { File.Delete(tempPath); } catch { /* best-effort */ }
        }
    }

    public string WriteMergedConfigurationSnapshot(
        string? configurationPath = null,
        Action<JsonObject>? mutateTranscription = null,
        bool applyDesktopRuntimeOverrides = false)
    {
        Directory.CreateDirectory(AppSupportDir);

        var bundledPath = ResolveBundledConfigPath(AppContext.BaseDirectory);
        var merged = MergeJsonFiles(bundledPath, UserConfigPath, configurationPath);
        var normalized = NormalizeDesktopConfiguration(merged);
        var root = JsonNode.Parse(normalized)?.AsObject()
            ?? throw new InvalidOperationException("Merged desktop configuration is not a JSON object.");
        var transcription = root["transcription"]?.AsObject()
            ?? throw new InvalidOperationException("Merged desktop configuration is missing the transcription section.");

        if (applyDesktopRuntimeOverrides && DesktopCliSupport.ShouldUseCliBridge())
        {
            ApplyCliBridgeCompatibilityOverrides(transcription);
        }

        mutateTranscription?.Invoke(transcription);

        var tempPath = Path.Combine(Path.GetTempPath(), $"voxflow-merged-{Guid.NewGuid():N}.json");
        File.WriteAllText(tempPath, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        return tempPath;
    }

    private static void ApplyCliBridgeCompatibilityOverrides(JsonObject transcription)
    {
        if (transcription["startupValidation"] is not JsonObject startupValidation)
        {
            return;
        }

        startupValidation["checkModelLoadability"] = false;
        startupValidation["checkWhisperRuntime"] = false;
        startupValidation["checkLanguageSupport"] = false;
    }

    public IReadOnlyList<SupportedLanguage> GetSupportedLanguages(string? configurationPath = null)
    {
        var options = LoadAsync(configurationPath).GetAwaiter().GetResult();
        return options.SupportedLanguages
            .Select((lang, i) => new SupportedLanguage(lang.Code, lang.DisplayName, i))
            .ToList();
    }

    public async Task SaveUserOverridesAsync(Dictionary<string, object> overrides)
    {
        Directory.CreateDirectory(AppSupportDir);
        var json = JsonSerializer.Serialize(
            new { transcription = overrides },
            new JsonSerializerOptions { WriteIndented = true });
        await File.WriteAllTextAsync(UserConfigPath, json);
    }

    internal static string ResolveBundledConfigPath(string baseDirectory)
    {
        var candidates = new[]
        {
            Path.Combine(baseDirectory, "appsettings.json"),
            Path.GetFullPath(Path.Combine(baseDirectory, "..", "Resources", "appsettings.json")),
            Path.GetFullPath(Path.Combine(baseDirectory, "..", "..", "Resources", "appsettings.json"))
        };

        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return candidates[0];
    }

    internal static string NormalizeDesktopConfiguration(string json)
    {
        return NormalizeDesktopConfiguration(json, AppSupportDir, DocumentsDir);
    }

    internal static string NormalizeDesktopConfiguration(string json, string appSupportDir, string documentsDir)
    {
        var root = JsonNode.Parse(json)?.AsObject();
        if (root is null || root["transcription"] is not JsonObject transcription)
        {
            return json;
        }

        transcription["inputFilePath"] = ResolveDesktopPath(
            transcription["inputFilePath"]?.GetValue<string>(),
            documentsDir,
            "input.m4a");
        transcription["wavFilePath"] = ResolveDesktopPath(
            transcription["wavFilePath"]?.GetValue<string>(),
            appSupportDir,
            Path.Combine("artifacts", "output.wav"));
        transcription["resultFilePath"] = ResolveDesktopPath(
            transcription["resultFilePath"]?.GetValue<string>(),
            documentsDir,
            "result.txt");
        transcription["modelFilePath"] = ResolveDesktopPath(
            transcription["modelFilePath"]?.GetValue<string>(),
            appSupportDir,
            Path.Combine("models", "ggml-base.bin"));

        if (transcription["batch"] is JsonObject batch)
        {
            batch["inputDirectory"] = ResolveDesktopPath(
                batch["inputDirectory"]?.GetValue<string>(),
                documentsDir,
                "input");
            batch["outputDirectory"] = ResolveDesktopPath(
                batch["outputDirectory"]?.GetValue<string>(),
                documentsDir,
                "output");
            batch["tempDirectory"] = ResolveDesktopPath(
                batch["tempDirectory"]?.GetValue<string>(),
                appSupportDir,
                "temp");
            batch["summaryFilePath"] = ResolveDesktopPath(
                batch["summaryFilePath"]?.GetValue<string>(),
                documentsDir,
                "batch-summary.txt");
        }

        EnsureFileParentDirectory(transcription["wavFilePath"]?.GetValue<string>());
        EnsureFileParentDirectory(transcription["resultFilePath"]?.GetValue<string>());
        EnsureFileParentDirectory(transcription["modelFilePath"]?.GetValue<string>());

        if (transcription["batch"] is JsonObject normalizedBatch)
        {
            EnsureDirectory(normalizedBatch["outputDirectory"]?.GetValue<string>());
            EnsureDirectory(normalizedBatch["tempDirectory"]?.GetValue<string>());
            EnsureFileParentDirectory(normalizedBatch["summaryFilePath"]?.GetValue<string>());
        }

        return root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    internal static string ResolveDesktopPath(string? configuredPath, string rootDirectory, string defaultRelativePath)
    {
        var trimmed = string.IsNullOrWhiteSpace(configuredPath)
            ? defaultRelativePath
            : configuredPath.Trim();

        var expanded = ExpandHomeDirectory(trimmed);
        if (Path.IsPathRooted(expanded))
        {
            return Path.GetFullPath(expanded);
        }

        return Path.GetFullPath(Path.Combine(rootDirectory, expanded));
    }

    private static string ExpandHomeDirectory(string path)
    {
        if (path == "~")
        {
            return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }

        if (path.StartsWith("~/", StringComparison.Ordinal) || path.StartsWith("~\\", StringComparison.Ordinal))
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return Path.Combine(home, path[2..]);
        }

        return path;
    }

    private static void EnsureDirectory(string? directoryPath)
    {
        if (!string.IsNullOrWhiteSpace(directoryPath))
        {
            Directory.CreateDirectory(directoryPath);
        }
    }

    private static void EnsureFileParentDirectory(string? filePath)
    {
        if (string.IsNullOrWhiteSpace(filePath))
        {
            return;
        }

        var directory = Path.GetDirectoryName(filePath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }
    }

    internal static string MergeJsonFiles(string basePath, string userPath, string? overridePath)
    {
        using var baseDoc = File.Exists(basePath)
            ? JsonDocument.Parse(File.ReadAllText(basePath))
            : JsonDocument.Parse("{}");

        var merged = CloneJsonElement(baseDoc.RootElement);

        if (File.Exists(userPath))
        {
            using var userDoc = JsonDocument.Parse(File.ReadAllText(userPath));
            MergeInto(merged, userDoc.RootElement);
        }

        if (overridePath != null && File.Exists(overridePath))
        {
            using var overrideDoc = JsonDocument.Parse(File.ReadAllText(overridePath));
            MergeInto(merged, overrideDoc.RootElement);
        }

        return JsonSerializer.Serialize(merged, new JsonSerializerOptions { WriteIndented = true });
    }

    private static Dictionary<string, object?> CloneJsonElement(JsonElement element)
    {
        var dict = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        foreach (var prop in element.EnumerateObject())
        {
            dict[prop.Name] = prop.Value.ValueKind == JsonValueKind.Object
                ? CloneJsonElement(prop.Value)
                : JsonSerializer.Deserialize<object>(prop.Value.GetRawText());
        }
        return dict;
    }

    private static void MergeInto(Dictionary<string, object?> target, JsonElement source)
    {
        foreach (var prop in source.EnumerateObject())
        {
            if (prop.Value.ValueKind == JsonValueKind.Object
                && target.TryGetValue(prop.Name, out var existing)
                && existing is Dictionary<string, object?> existingDict)
            {
                MergeInto(existingDict, prop.Value);
            }
            else
            {
                target[prop.Name] = prop.Value.ValueKind == JsonValueKind.Object
                    ? CloneJsonElement(prop.Value)
                    : JsonSerializer.Deserialize<object>(prop.Value.GetRawText());
            }
        }
    }
}
