namespace VoxFlow.Core.Models;

public sealed record ValidationResult(
    string Outcome,
    bool CanStart,
    bool HasWarnings,
    string ResolvedConfigurationPath,
    IReadOnlyList<ValidationCheck> Checks);
