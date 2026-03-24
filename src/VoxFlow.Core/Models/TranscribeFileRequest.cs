namespace VoxFlow.Core.Models;

public sealed record TranscribeFileRequest(
    string InputPath,
    string? ResultFilePath = null,
    string? ConfigurationPath = null,
    IReadOnlyList<string>? ForceLanguages = null,
    bool OverwriteExistingResult = true);
