namespace VoxFlow.Core.Models;

public sealed record ValidationCheck(
    string Name,
    ValidationCheckStatus Status,
    string Details);

public enum ValidationCheckStatus
{
    Passed,
    Warning,
    Failed,
    Skipped
}
