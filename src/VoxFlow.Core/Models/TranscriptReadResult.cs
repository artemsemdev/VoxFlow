namespace VoxFlow.Core.Models;

public sealed record TranscriptReadResult(
    string Path,
    string Content,
    long TotalLength,
    bool WasTruncated);
