#nullable enable
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;

namespace VoxFlow.Core.Services;

/// <summary>
/// Provides configuration loading and language discovery.
/// </summary>
internal sealed class ConfigurationService : IConfigurationService
{
    /// <summary>
    /// Loads transcription options from the specified or default configuration path.
    /// </summary>
    public Task<TranscriptionOptions> LoadAsync(string? configurationPath = null)
    {
        var options = configurationPath != null
            ? TranscriptionOptions.LoadFromPath(configurationPath)
            : TranscriptionOptions.Load();
        return Task.FromResult(options);
    }

    /// <summary>
    /// Returns the list of supported languages from the configuration.
    /// </summary>
    public IReadOnlyList<SupportedLanguage> GetSupportedLanguages(string? configurationPath = null)
    {
        var options = configurationPath != null
            ? TranscriptionOptions.LoadFromPath(configurationPath)
            : TranscriptionOptions.Load();

        return options.SupportedLanguages
            .Select((lang, i) => new SupportedLanguage(lang.Code, lang.DisplayName, i))
            .ToList();
    }
}
