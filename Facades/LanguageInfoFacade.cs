#nullable enable
using System.Collections.Generic;
using System.Linq;

/// <summary>
/// Provides language configuration information as structured DTOs.
/// </summary>
internal sealed class LanguageInfoFacade : ILanguageInfoFacade
{
    public IReadOnlyList<SupportedLanguageDto> GetSupportedLanguages(string? configurationPath = null)
    {
        var options = string.IsNullOrWhiteSpace(configurationPath)
            ? TranscriptionOptions.Load()
            : TranscriptionOptions.LoadFromPath(configurationPath);

        return options.SupportedLanguages
            .Select(lang => new SupportedLanguageDto(lang.Code, lang.DisplayName, lang.Priority))
            .ToArray();
    }
}
