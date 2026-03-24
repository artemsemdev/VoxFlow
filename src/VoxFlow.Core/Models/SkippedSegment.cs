namespace VoxFlow.Core.Models;

public sealed record SkippedSegment(
    TimeSpan Start,
    TimeSpan End,
    string Text,
    double Probability,
    SegmentSkipReason Reason);

public enum SegmentSkipReason
{
    EmptyText,
    NoiseMarker,
    BracketedPlaceholder,
    LowProbability,
    LowInformationLong,
    SuspiciousNonSpeech,
    RepetitiveLoop
}
