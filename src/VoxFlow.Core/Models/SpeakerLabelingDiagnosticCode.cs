namespace VoxFlow.Core.Models;

/// <summary>
/// Stable taxonomy of speaker-labeling readiness/failure states. Every host
/// (CLI, Desktop, MCP) maps these to user-actionable messages instead of
/// surfacing raw Python/pyannote internals. The stable string form
/// (<see cref="SpeakerLabelingDiagnosticCodes.ToStableString"/>) is the contract
/// callers and logs key off; the enum members may grow over time.
/// </summary>
/// <remarks>
/// Some codes are produced today by the transcription failure path (the sidecar
/// reasons and the preflight runtime states). The Python-introspection codes
/// (<see cref="TorchImportFailed"/>, <see cref="PyannoteImportFailed"/>,
/// <see cref="HuggingFaceTokenMissing"/>, <see cref="ModelLicenseRequired"/>,
/// <see cref="ModelNotCached"/>) are part of the contract for the forthcoming
/// <c>doctor speakers</c> / smoke-test work and are reserved here so hosts can
/// rely on a complete set.
/// </remarks>
public enum SpeakerLabelingDiagnosticCode
{
    // --- Python runtime preflight ---
    PythonNotFound,
    PythonVersionUnsupported,
    VenvMissing,
    VenvBootstrapFailed,

    // --- Dependency / model readiness (reserved for doctor/smoke work) ---
    TorchImportFailed,
    PyannoteImportFailed,
    HuggingFaceTokenMissing,
    ModelLicenseRequired,
    ModelNotCached,

    // --- Diarization sidecar invocation ---
    SidecarRuntimeNotReady,
    SidecarProcessCrashed,
    SidecarTimeout,
    SidecarMalformedJson,
    SidecarSchemaViolation,
    SidecarErrorResponse,

    // --- Fallback ---
    Unknown,
}
