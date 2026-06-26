using VoxFlow.Core.Models;
using VoxFlow.Core.Services.Python;

namespace VoxFlow.Core.Services.Diarization;

/// <summary>
/// Builds structured <see cref="SpeakerLabelingDiagnostic"/> values from the
/// signals the transcription path already produces — diarization-sidecar
/// failures and Python-runtime preflight states — so every host can present a
/// stable code, a clean summary, and a concrete next action instead of raw
/// Python/pyannote internals. Pure and deterministic; raw messages are carried
/// as <see cref="SpeakerLabelingDiagnostic.TechnicalDetail"/> for logs.
/// </summary>
public static class SpeakerLabelingDiagnostics
{
    /// <summary>
    /// Builds the diagnostic (summary + remediation) for a specific code, so other
    /// surfaces (e.g. the doctor health check) reuse the same wording.
    /// </summary>
    public static SpeakerLabelingDiagnostic ForCode(
        SpeakerLabelingDiagnosticCode code,
        string? technicalDetail = null)
    {
        var (summary, remediation) = Describe(code);
        return new SpeakerLabelingDiagnostic(code, SpeakerLabelingDiagnosticSeverity.Error, summary, remediation, technicalDetail);
    }

    public static SpeakerLabelingDiagnostic FromSidecar(SidecarFailureReason reason, string? message)
    {
        var code = reason switch
        {
            SidecarFailureReason.RuntimeNotReady => SpeakerLabelingDiagnosticCode.SidecarRuntimeNotReady,
            SidecarFailureReason.ProcessCrashed => SpeakerLabelingDiagnosticCode.SidecarProcessCrashed,
            SidecarFailureReason.Timeout => SpeakerLabelingDiagnosticCode.SidecarTimeout,
            SidecarFailureReason.MalformedJson => SpeakerLabelingDiagnosticCode.SidecarMalformedJson,
            SidecarFailureReason.SchemaViolation => SpeakerLabelingDiagnosticCode.SidecarSchemaViolation,
            SidecarFailureReason.ErrorResponseReturned => SpeakerLabelingDiagnosticCode.SidecarErrorResponse,
            _ => SpeakerLabelingDiagnosticCode.Unknown,
        };

        var (summary, remediation) = Describe(code);
        return new SpeakerLabelingDiagnostic(code, SpeakerLabelingDiagnosticSeverity.Error, summary, remediation, message);
    }

    public static SpeakerLabelingDiagnostic FromRuntimeStatus(PythonRuntimeStatus status)
    {
        System.ArgumentNullException.ThrowIfNull(status);

        var code = status.DiagnosticCode
                   ?? (status.CanBootstrap
                       ? SpeakerLabelingDiagnosticCode.VenvMissing
                       : SpeakerLabelingDiagnosticCode.SidecarRuntimeNotReady);

        var (summary, remediation) = Describe(code);
        return new SpeakerLabelingDiagnostic(code, SpeakerLabelingDiagnosticSeverity.Error, summary, remediation, status.Error);
    }

    public static SpeakerLabelingDiagnostic Timeout(int seconds)
    {
        var (_, remediation) = Describe(SpeakerLabelingDiagnosticCode.SidecarTimeout);
        return new SpeakerLabelingDiagnostic(
            SpeakerLabelingDiagnosticCode.SidecarTimeout,
            SpeakerLabelingDiagnosticSeverity.Error,
            $"Speaker labeling took longer than {seconds}s and was stopped.",
            remediation);
    }

    /// <summary>
    /// User-facing summary + remediation for every code. Centralized so the
    /// sidecar and preflight mappers stay consistent and every code is covered.
    /// </summary>
    private static (string Summary, string Remediation) Describe(SpeakerLabelingDiagnosticCode code) => code switch
    {
        SpeakerLabelingDiagnosticCode.PythonNotFound => (
            "A supported Python runtime could not be found.",
            "Install Python 3.10+ on PATH, or set transcription.speakerLabeling.pythonRuntimeMode to ManagedVenv."),
        SpeakerLabelingDiagnosticCode.PythonVersionUnsupported => (
            "The detected Python version is too old for speaker labeling.",
            "Install Python 3.10 or newer."),
        SpeakerLabelingDiagnosticCode.VenvMissing => (
            "The managed speaker-labeling runtime is not installed yet.",
            "Run the managed speaker-labeling setup to install it (see the speaker-labeling runbook)."),
        SpeakerLabelingDiagnosticCode.VenvBootstrapFailed => (
            "Installing the managed speaker-labeling runtime failed.",
            "Check disk space and network access, then retry setup; the failing step is in the logs."),
        SpeakerLabelingDiagnosticCode.TorchImportFailed => (
            "PyTorch could not be loaded by the speaker-labeling runtime.",
            "Reinstall the managed speaker-labeling runtime; if it persists, check the runtime logs."),
        SpeakerLabelingDiagnosticCode.PyannoteImportFailed => (
            "The pyannote.audio library could not be loaded.",
            "Reinstall the managed speaker-labeling runtime; if it persists, check the runtime logs."),
        SpeakerLabelingDiagnosticCode.HuggingFaceTokenMissing => (
            "A Hugging Face access token is required and was not found.",
            "Set HUGGING_FACE_HUB_TOKEN with a token that has accepted the model license."),
        SpeakerLabelingDiagnosticCode.ModelLicenseRequired => (
            "The diarization model's license has not been accepted.",
            "Accept the model license on Hugging Face for the account that owns your token."),
        SpeakerLabelingDiagnosticCode.ModelNotCached => (
            "The diarization model is not available in the local cache.",
            "Run setup with a valid token to download the model, or pre-populate the Hugging Face cache."),
        SpeakerLabelingDiagnosticCode.SidecarRuntimeNotReady => (
            "The speaker-labeling runtime was not ready when diarization started.",
            "Set up the speaker-labeling runtime, then retry."),
        SpeakerLabelingDiagnosticCode.SidecarProcessCrashed => (
            "The speaker-labeling engine stopped unexpectedly.",
            "Re-run; if it persists, check the logs and the speaker-labeling runbook."),
        SpeakerLabelingDiagnosticCode.SidecarTimeout => (
            "Speaker labeling took too long and was stopped.",
            "Increase transcription.speakerLabeling.timeoutSeconds, or use shorter audio."),
        SpeakerLabelingDiagnosticCode.SidecarMalformedJson => (
            "The speaker-labeling engine returned unreadable output.",
            "This usually means a corrupted runtime; reinstall the speaker-labeling runtime."),
        SpeakerLabelingDiagnosticCode.SidecarSchemaViolation => (
            "The speaker-labeling engine returned output in an unexpected shape.",
            "Update VoxFlow and the runtime to matching versions; report it if it persists."),
        SpeakerLabelingDiagnosticCode.SidecarErrorResponse => (
            "The speaker-labeling engine reported an error.",
            "See the logs for details (often a Hugging Face token or model-license issue)."),
        SpeakerLabelingDiagnosticCode.Unknown => (
            "Speaker labeling failed for an unrecognized reason.",
            "Check the logs; if it persists, report it with the technical detail."),
        _ => (
            "Speaker labeling failed for an unrecognized reason.",
            "Check the logs; if it persists, report it with the technical detail."),
    };
}
