namespace VoxFlow.Core.Models;

public sealed record FilteredSegment(
    TimeSpan Start,
    TimeSpan End,
    string Text,
    double Probability);
