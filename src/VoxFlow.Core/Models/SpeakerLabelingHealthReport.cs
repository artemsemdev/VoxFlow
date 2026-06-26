using System.Collections.Generic;

namespace VoxFlow.Core.Models;

/// <summary>Per-check outcome in a speaker-labeling health report.</summary>
public enum HealthCheckStatus
{
    /// <summary>The check passed.</summary>
    Ok,

    /// <summary>The check failed and blocks readiness.</summary>
    Fail,

    /// <summary>The check could not be run now (e.g. needs the live runtime); not a blocker.</summary>
    Skip,
}

/// <summary>A single named readiness check with a scan-friendly status and detail.</summary>
public sealed record HealthCheck(string Name, HealthCheckStatus Status, string Detail);

/// <summary>
/// The result of a <c>doctor speakers</c> run: the individual checks, whether the
/// runtime is ready overall (no failing check), and the single most relevant next
/// action when it is not.
/// </summary>
public sealed record SpeakerLabelingHealthReport(
    bool IsReady,
    IReadOnlyList<HealthCheck> Checks,
    string? NextAction);
