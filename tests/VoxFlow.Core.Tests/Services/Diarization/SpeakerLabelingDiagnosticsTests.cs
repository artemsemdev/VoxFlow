using VoxFlow.Core.Models;
using VoxFlow.Core.Services.Diarization;
using VoxFlow.Core.Services.Python;
using Xunit;

namespace VoxFlow.Core.Tests.Services.Diarization;

public sealed class SpeakerLabelingDiagnosticsTests
{
    [Theory]
    [InlineData(SpeakerLabelingDiagnosticCode.PythonNotFound, "python-not-found")]
    [InlineData(SpeakerLabelingDiagnosticCode.PythonVersionUnsupported, "python-version-unsupported")]
    [InlineData(SpeakerLabelingDiagnosticCode.VenvMissing, "venv-missing")]
    [InlineData(SpeakerLabelingDiagnosticCode.VenvBootstrapFailed, "venv-bootstrap-failed")]
    [InlineData(SpeakerLabelingDiagnosticCode.HuggingFaceTokenMissing, "hf-token-missing")]
    [InlineData(SpeakerLabelingDiagnosticCode.ModelLicenseRequired, "model-license-required")]
    [InlineData(SpeakerLabelingDiagnosticCode.ModelNotCached, "model-not-cached")]
    [InlineData(SpeakerLabelingDiagnosticCode.SidecarProcessCrashed, "process-crashed")]
    [InlineData(SpeakerLabelingDiagnosticCode.SidecarTimeout, "timeout")]
    [InlineData(SpeakerLabelingDiagnosticCode.SidecarMalformedJson, "malformed-json")]
    [InlineData(SpeakerLabelingDiagnosticCode.SidecarSchemaViolation, "schema-violation")]
    [InlineData(SpeakerLabelingDiagnosticCode.SidecarErrorResponse, "error-response-returned")]
    [InlineData(SpeakerLabelingDiagnosticCode.Unknown, "unknown-speaker-labeling-failure")]
    public void ToStableString_IsKebabCase(SpeakerLabelingDiagnosticCode code, string expected)
    {
        Assert.Equal(expected, SpeakerLabelingDiagnosticCodes.ToStableString(code));
    }

    [Fact]
    public void EveryCode_HasAStableString()
    {
        foreach (SpeakerLabelingDiagnosticCode code in System.Enum.GetValues<SpeakerLabelingDiagnosticCode>())
        {
            var s = SpeakerLabelingDiagnosticCodes.ToStableString(code);
            Assert.False(string.IsNullOrWhiteSpace(s));
            Assert.DoesNotContain('_', s);
            Assert.Equal(s.ToLowerInvariant(), s);
        }
    }

    [Theory]
    [InlineData(SidecarFailureReason.RuntimeNotReady, SpeakerLabelingDiagnosticCode.SidecarRuntimeNotReady)]
    [InlineData(SidecarFailureReason.ProcessCrashed, SpeakerLabelingDiagnosticCode.SidecarProcessCrashed)]
    [InlineData(SidecarFailureReason.Timeout, SpeakerLabelingDiagnosticCode.SidecarTimeout)]
    [InlineData(SidecarFailureReason.MalformedJson, SpeakerLabelingDiagnosticCode.SidecarMalformedJson)]
    [InlineData(SidecarFailureReason.SchemaViolation, SpeakerLabelingDiagnosticCode.SidecarSchemaViolation)]
    [InlineData(SidecarFailureReason.ErrorResponseReturned, SpeakerLabelingDiagnosticCode.SidecarErrorResponse)]
    public void FromSidecar_MapsEveryReasonDeterministically(SidecarFailureReason reason, SpeakerLabelingDiagnosticCode expected)
    {
        var d = SpeakerLabelingDiagnostics.FromSidecar(reason, "raw technical message");

        Assert.Equal(expected, d.Code);
        Assert.Equal(SpeakerLabelingDiagnosticSeverity.Error, d.Severity);
        Assert.False(string.IsNullOrWhiteSpace(d.Summary));
        Assert.False(string.IsNullOrWhiteSpace(d.Remediation));
        Assert.Equal("raw technical message", d.TechnicalDetail);
    }

    [Fact]
    public void FromRuntimeStatus_UsesStructuredCode_WhenPresent()
    {
        var status = PythonRuntimeStatus.NotReady("python3 not found in PATH")
            with { DiagnosticCode = SpeakerLabelingDiagnosticCode.PythonNotFound };

        var d = SpeakerLabelingDiagnostics.FromRuntimeStatus(status);

        Assert.Equal(SpeakerLabelingDiagnosticCode.PythonNotFound, d.Code);
        Assert.Contains("python-not-found", d.CodeString);
        Assert.False(string.IsNullOrWhiteSpace(d.Remediation));
        Assert.Equal("python3 not found in PATH", d.TechnicalDetail);
    }

    [Fact]
    public void FromRuntimeStatus_BootstrappableWithoutCode_MapsToVenvMissing()
    {
        var status = PythonRuntimeStatus.NotReadyBootstrapable("Managed venv not yet created.");

        var d = SpeakerLabelingDiagnostics.FromRuntimeStatus(status);

        Assert.Equal(SpeakerLabelingDiagnosticCode.VenvMissing, d.Code);
    }

    [Fact]
    public void FromRuntimeStatus_NotReadyWithoutCode_MapsToRuntimeNotReady()
    {
        var status = PythonRuntimeStatus.NotReady("something opaque");

        var d = SpeakerLabelingDiagnostics.FromRuntimeStatus(status);

        Assert.Equal(SpeakerLabelingDiagnosticCode.SidecarRuntimeNotReady, d.Code);
    }

    [Fact]
    public void Timeout_ProducesTimeoutDiagnostic_WithSecondsInSummary()
    {
        var d = SpeakerLabelingDiagnostics.Timeout(42);

        Assert.Equal(SpeakerLabelingDiagnosticCode.SidecarTimeout, d.Code);
        Assert.Contains("42", d.Summary);
        Assert.False(string.IsNullOrWhiteSpace(d.Remediation));
    }
}
