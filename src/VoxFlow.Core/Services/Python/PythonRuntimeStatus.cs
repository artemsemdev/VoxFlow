using VoxFlow.Core.Models;

namespace VoxFlow.Core.Services.Python;

/// <summary>
/// Outcome of probing an <see cref="VoxFlow.Core.Interfaces.IPythonRuntime"/>.
/// A ready status has a non-null <see cref="InterpreterPath"/> and
/// <see cref="Version"/>; a not-ready status has a non-null
/// <see cref="Error"/> explaining why. <see cref="CanBootstrap"/> is true
/// when the runtime is recoverable via a managed-venv bootstrap step (e.g.,
/// the venv has not been created yet). <see cref="DiagnosticCode"/> classifies
/// a not-ready status into a stable speaker-labeling diagnostic when the
/// runtime can pin down the reason; it is null when the cause is unclassified.
/// </summary>
public sealed record PythonRuntimeStatus(
    bool IsReady,
    string? InterpreterPath,
    string? Version,
    string? Error,
    bool CanBootstrap = false)
{
    /// <summary>
    /// Structured classification of a not-ready status, set by the runtime at
    /// the point of failure so callers do not have to parse <see cref="Error"/>.
    /// </summary>
    public SpeakerLabelingDiagnosticCode? DiagnosticCode { get; init; }

    public static PythonRuntimeStatus Ready(string interpreterPath, string version)
        => new(IsReady: true, interpreterPath, version, Error: null);

    public static PythonRuntimeStatus NotReady(string error, SpeakerLabelingDiagnosticCode? code = null)
        => new(IsReady: false, InterpreterPath: null, Version: null, error) { DiagnosticCode = code };

    public static PythonRuntimeStatus NotReadyBootstrapable(string error, SpeakerLabelingDiagnosticCode? code = null)
        => new(IsReady: false, InterpreterPath: null, Version: null, error, CanBootstrap: true) { DiagnosticCode = code };
}
