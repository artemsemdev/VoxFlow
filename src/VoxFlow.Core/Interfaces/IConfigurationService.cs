using VoxFlow.Core.Configuration;
using VoxFlow.Core.Models;

namespace VoxFlow.Core.Interfaces;

public interface IConfigurationService
{
    Task<TranscriptionOptions> LoadAsync(string? configurationPath = null);
    IReadOnlyList<SupportedLanguage> GetSupportedLanguages(string? configurationPath = null);
}
