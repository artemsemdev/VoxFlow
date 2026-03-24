namespace VoxFlow.Core.Models;

public sealed record LanguageSelectionResult(
    SupportedLanguage Language,
    double Score,
    TimeSpan AudioDuration,
    IReadOnlyList<FilteredSegment> AcceptedSegments,
    IReadOnlyList<SkippedSegment> SkippedSegments,
    string? Warning = null);
