namespace VoxFlow.Core.Models;

/// <summary>How serious a <see cref="SpeakerLabelingDiagnostic"/> is.</summary>
public enum SpeakerLabelingDiagnosticSeverity
{
    Info,
    Warning,
    Error,
}

/// <summary>
/// A structured speaker-labeling readiness/failure state. Carries a stable
/// <see cref="Code"/>, a user-facing <see cref="Summary"/> and a concrete
/// <see cref="Remediation"/> (the next action), plus optional
/// <see cref="TechnicalDetail"/> intended for logs rather than normal user
/// output. Hosts render <see cref="Summary"/>/<see cref="Remediation"/>;
/// raw Python/pyannote internals belong in <see cref="TechnicalDetail"/>.
/// </summary>
public sealed record SpeakerLabelingDiagnostic(
    SpeakerLabelingDiagnosticCode Code,
    SpeakerLabelingDiagnosticSeverity Severity,
    string Summary,
    string Remediation,
    string? TechnicalDetail = null)
{
    /// <summary>The stable kebab-case string form of <see cref="Code"/>.</summary>
    public string CodeString => SpeakerLabelingDiagnosticCodes.ToStableString(Code);

    /// <summary>
    /// A single-line, user-facing warning string of the form
    /// <c>speaker-labeling: &lt;code&gt;: &lt;summary&gt; &lt;remediation&gt;</c>.
    /// Carries the next action but never the raw technical detail, which belongs
    /// in logs.
    /// </summary>
    public string ToWarningString()
        => $"speaker-labeling: {CodeString}: {Summary} {Remediation}".Trim();
}
