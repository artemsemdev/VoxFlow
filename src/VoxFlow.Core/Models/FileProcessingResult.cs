namespace VoxFlow.Core.Models;

public sealed record FileProcessingResult(
    string InputPath,
    string OutputPath,
    FileProcessingStatus Status,
    string? ErrorMessage,
    TimeSpan Duration,
    string? DetectedLanguage);

public enum FileProcessingStatus
{
    Success,
    Failed,
    Skipped
}
