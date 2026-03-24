using System.Text.Json;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;

namespace VoxFlow.Desktop.Configuration;

public sealed class DesktopConfigurationService : IConfigurationService
{
    private static readonly string AppSupportDir =
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "VoxFlow");

    private static readonly string UserConfigPath =
        Path.Combine(AppSupportDir, "appsettings.json");

    public Task<TranscriptionOptions> LoadAsync(string? configurationPath = null)
    {
        Directory.CreateDirectory(AppSupportDir);

        var bundledPath = Path.Combine(AppContext.BaseDirectory, "appsettings.json");

        var merged = MergeJsonFiles(bundledPath, UserConfigPath, configurationPath);

        var tempPath = Path.Combine(Path.GetTempPath(), $"voxflow-merged-{Guid.NewGuid()}.json");
        try
        {
            File.WriteAllText(tempPath, merged);
            var options = TranscriptionOptions.LoadFromPath(tempPath);
            return Task.FromResult(options);
        }
        finally
        {
            try { File.Delete(tempPath); } catch { /* best-effort */ }
        }
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
