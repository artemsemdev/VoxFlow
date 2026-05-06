using System.Text.Json;
using System.Text.Json.Nodes;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using VoxFlow.Desktop.Services;

namespace VoxFlow.Desktop.Configuration;

public class DesktopConfigurationService : IConfigurationService
{
    private static readonly string DefaultAppSupportDir =
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Library",
            "Application Support",
            "VoxFlow");

    private static readonly string DefaultDocumentsDir =
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            "VoxFlow");

    private readonly string _appSupportDir;
    private readonly string _documentsDir;
    private readonly string _userConfigPath;

    public DesktopConfigurationService()
        : this(DefaultAppSupportDir, DefaultDocumentsDir)
    {
    }

    // Overrideable for tests so the user config file lands in a temp directory
    // instead of the real ~/Library/Application Support/VoxFlow location.
    public DesktopConfigurationService(string appSupportDir, string documentsDir)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(appSupportDir);
        ArgumentException.ThrowIfNullOrWhiteSpace(documentsDir);
        _appSupportDir = appSupportDir;
        _documentsDir = documentsDir;
        _userConfigPath = Path.Combine(appSupportDir, "appsettings.json");
    }

    public Task<TranscriptionOptions> LoadAsync(string? configurationPath = null)
        => Task.FromResult(LoadCore(configurationPath));

    // Sync core for the configuration load. Both LoadAsync and GetSupportedLanguages
    // share this so neither has to wait synchronously on the other's Task.
    // The work is genuinely synchronous (file merge + parse + best-effort cleanup),
    // so wrapping it in Task.FromResult inside LoadAsync keeps the existing async
    // surface for callers that prefer it.
    private TranscriptionOptions LoadCore(string? configurationPath)
    {
        var tempPath = WriteMergedConfigurationSnapshot(configurationPath, applyDesktopRuntimeOverrides: true);
        try
        {
            return TranscriptionOptions.LoadFromPath(tempPath);
        }
        finally
        {
            try
            {
                File.Delete(tempPath);
            }
            catch (IOException)
            {
                // Temp snapshots are disposable merge artifacts, so cleanup is best-effort.
            }
            catch (UnauthorizedAccessException)
            {
                // Temp snapshots are disposable merge artifacts, so cleanup is best-effort.
            }
        }
    }

    public string WriteMergedConfigurationSnapshot(
        string? configurationPath = null,
        Action<JsonObject>? mutateTranscription = null,
        bool applyDesktopRuntimeOverrides = false)
    {
        Directory.CreateDirectory(_appSupportDir);

        var bundledPath = ResolveBundledConfigPath(AppContext.BaseDirectory);
        // Materialize a merged temp file so the core configuration pipeline can stay file-based across CLI, desktop, and tests.
        var merged = MergeJsonFiles(bundledPath, _userConfigPath, configurationPath);
        var normalized = NormalizeDesktopConfiguration(merged, _appSupportDir, _documentsDir);
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

        // The CLI bridge validates in a separate process, so in-process native runtime probes would fail for the wrong reason here.
        startupValidation["checkModelLoadability"] = false;
        startupValidation["checkWhisperRuntime"] = false;
        startupValidation["checkLanguageSupport"] = false;
    }

    public IReadOnlyList<SupportedLanguage> GetSupportedLanguages(string? configurationPath = null)
    {
        // Use the sync core directly. Calling LoadAsync(...).GetAwaiter().GetResult()
        // here would be sync-over-async even though LoadAsync's body is itself sync
        // (Task.FromResult); the pattern still ties up a thread-pool worker on UI
        // sync contexts and signals risk to readers.
        var options = LoadCore(configurationPath);
        return options.SupportedLanguages
            .Select((lang, i) => new SupportedLanguage(lang.Code, lang.DisplayName, i))
            .ToList();
    }

    public virtual async Task SaveUserOverridesAsync(Dictionary<string, object> overrides)
    {
        Directory.CreateDirectory(_appSupportDir);

        // Read existing user overrides (if any), deep-merge the new entries
        // under the transcription section, and write back. The merge keeps
        // previously saved keys (e.g. resultFormat) alive when a different
        // setting is toggled, instead of stamping a fresh file each time.
        var root = JsonNode.Parse(
            File.Exists(_userConfigPath)
                ? await File.ReadAllTextAsync(_userConfigPath)
                : "{}")?.AsObject()
            ?? new JsonObject();

        if (root["transcription"] is not JsonObject transcription)
        {
            transcription = new JsonObject();
            root["transcription"] = transcription;
        }

        foreach (var kvp in overrides)
        {
            MergeOverrideValue(transcription, kvp.Key, kvp.Value);
        }

        await File.WriteAllTextAsync(
            _userConfigPath,
            root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }

    private static void MergeOverrideValue(JsonObject target, string key, object? value)
    {
        if (value is null)
        {
            target[key] = null;
            return;
        }

        if (value is IDictionary<string, object?> nullableDict)
        {
            MergeNestedDictionary(target, key, nullableDict);
            return;
        }

        if (value is IDictionary<string, object> nestedDict)
        {
            MergeNestedDictionary(
                target,
                key,
                nestedDict.ToDictionary(kvp => kvp.Key, kvp => (object?)kvp.Value));
            return;
        }

        target[key] = JsonNode.Parse(JsonSerializer.Serialize(value));
    }

    private static void MergeNestedDictionary(
        JsonObject target,
        string key,
        IDictionary<string, object?> source)
    {
        if (target[key] is not JsonObject existing)
        {
            existing = new JsonObject();
            target[key] = existing;
        }

        foreach (var inner in source)
        {
            MergeOverrideValue(existing, inner.Key, inner.Value);
        }
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
