using System;

namespace VoxFlow.Core.Models;

/// <summary>
/// Maps <see cref="SpeakerLabelingDiagnosticCode"/> to its stable, kebab-case
/// string form. Kebab-case matches the existing <c>speaker-labeling: …</c>
/// warning vocabulary, so logs and host output stay greppable and consistent.
/// </summary>
public static class SpeakerLabelingDiagnosticCodes
{
    public static string ToStableString(SpeakerLabelingDiagnosticCode code) => code switch
    {
        SpeakerLabelingDiagnosticCode.PythonNotFound => "python-not-found",
        SpeakerLabelingDiagnosticCode.PythonVersionUnsupported => "python-version-unsupported",
        SpeakerLabelingDiagnosticCode.VenvMissing => "venv-missing",
        SpeakerLabelingDiagnosticCode.VenvBootstrapFailed => "venv-bootstrap-failed",
        SpeakerLabelingDiagnosticCode.TorchImportFailed => "torch-import-failed",
        SpeakerLabelingDiagnosticCode.PyannoteImportFailed => "pyannote-import-failed",
        SpeakerLabelingDiagnosticCode.HuggingFaceTokenMissing => "hf-token-missing",
        SpeakerLabelingDiagnosticCode.ModelLicenseRequired => "model-license-required",
        SpeakerLabelingDiagnosticCode.ModelNotCached => "model-not-cached",
        SpeakerLabelingDiagnosticCode.SidecarRuntimeNotReady => "runtime-not-ready",
        SpeakerLabelingDiagnosticCode.SidecarProcessCrashed => "process-crashed",
        SpeakerLabelingDiagnosticCode.SidecarTimeout => "timeout",
        SpeakerLabelingDiagnosticCode.SidecarMalformedJson => "malformed-json",
        SpeakerLabelingDiagnosticCode.SidecarSchemaViolation => "schema-violation",
        SpeakerLabelingDiagnosticCode.SidecarErrorResponse => "error-response-returned",
        SpeakerLabelingDiagnosticCode.Unknown => "unknown-speaker-labeling-failure",
        _ => throw new ArgumentOutOfRangeException(nameof(code), code, "Unmapped speaker-labeling diagnostic code."),
    };
}
