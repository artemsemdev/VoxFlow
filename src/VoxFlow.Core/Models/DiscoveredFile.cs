namespace VoxFlow.Core.Models;

public sealed record DiscoveredFile(
    string InputPath,
    string OutputPath,
    string TempWavPath,
    DiscoveryStatus Status,
    string? SkipReason);

public enum DiscoveryStatus
{
    Ready,
    Skipped
}
