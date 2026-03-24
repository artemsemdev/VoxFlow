namespace VoxFlow.Core.Models;

public sealed record SupportedLanguage(
    string Code,
    string DisplayName,
    int Priority = 0);
