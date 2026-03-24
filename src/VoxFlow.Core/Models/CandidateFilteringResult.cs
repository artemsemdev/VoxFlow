namespace VoxFlow.Core.Models;

public sealed record CandidateFilteringResult(
    IReadOnlyList<FilteredSegment> Accepted,
    IReadOnlyList<SkippedSegment> Skipped);
