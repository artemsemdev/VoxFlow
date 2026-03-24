namespace VoxFlow.Core.Models;

public sealed record TranscribeFileResult(
    bool Success,
    string? DetectedLanguage,
    string? ResultFilePath,
    int AcceptedSegmentCount,
    int SkippedSegmentCount,
    TimeSpan Duration,
    IReadOnlyList<string> Warnings,
    string? TranscriptPreview);
