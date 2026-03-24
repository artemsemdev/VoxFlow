namespace VoxFlow.Core.Models;

public sealed record BatchTranscribeResult(
    int TotalFiles,
    int Succeeded,
    int Failed,
    int Skipped,
    string? SummaryFilePath,
    TimeSpan TotalDuration,
    IReadOnlyList<BatchFileResult> Results);

public sealed record BatchFileResult(
    string InputPath,
    string OutputPath,
    string Status,
    string? ErrorMessage,
    TimeSpan Duration,
    string? DetectedLanguage);
