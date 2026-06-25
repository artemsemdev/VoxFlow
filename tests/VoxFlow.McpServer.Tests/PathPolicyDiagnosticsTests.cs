#nullable enable
using System;
using System.Linq;
using VoxFlow.McpServer.Security;
using Xunit;

public sealed class PathPolicyDiagnosticsTests
{
    [Fact]
    public void Describe_WithEmptyInputRoots_EmitsUnrestrictedWarning()
    {
        var diagnostics = PathPolicyDiagnostics.Describe(
            allowedInputRoots: Array.Empty<string>(),
            allowedOutputRoots: new[] { "/allowed/output" },
            requireAbsolutePaths: true);

        var warning = Assert.Single(diagnostics, d =>
            d.Level == PathPolicyDiagnosticLevel.Warning &&
            d.Message.Contains("input", StringComparison.OrdinalIgnoreCase));

        Assert.Contains("UNRESTRICTED", warning.Message, StringComparison.Ordinal);
        Assert.Contains("allowedInputRoots", warning.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Describe_WithEmptyOutputRoots_EmitsUnrestrictedWarning()
    {
        var diagnostics = PathPolicyDiagnostics.Describe(
            allowedInputRoots: new[] { "/allowed/input" },
            allowedOutputRoots: Array.Empty<string>(),
            requireAbsolutePaths: true);

        var warning = Assert.Single(diagnostics, d =>
            d.Level == PathPolicyDiagnosticLevel.Warning &&
            d.Message.Contains("output", StringComparison.OrdinalIgnoreCase));

        Assert.Contains("UNRESTRICTED", warning.Message, StringComparison.Ordinal);
        Assert.Contains("allowedOutputRoots", warning.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Describe_WithConfiguredRoots_EmitsInformationListingRoots()
    {
        var diagnostics = PathPolicyDiagnostics.Describe(
            allowedInputRoots: new[] { "/allowed/input" },
            allowedOutputRoots: new[] { "/allowed/output" },
            requireAbsolutePaths: true);

        Assert.DoesNotContain(diagnostics, d => d.Level == PathPolicyDiagnosticLevel.Warning);
        Assert.Contains(diagnostics, d =>
            d.Level == PathPolicyDiagnosticLevel.Information &&
            d.Message.Contains("/allowed/input", StringComparison.Ordinal));
        Assert.Contains(diagnostics, d =>
            d.Level == PathPolicyDiagnosticLevel.Information &&
            d.Message.Contains("/allowed/output", StringComparison.Ordinal));
    }

    [Fact]
    public void Describe_WithRequireAbsolutePathsDisabled_EmitsWarning()
    {
        var diagnostics = PathPolicyDiagnostics.Describe(
            allowedInputRoots: new[] { "/allowed/input" },
            allowedOutputRoots: new[] { "/allowed/output" },
            requireAbsolutePaths: false);

        Assert.Contains(diagnostics, d =>
            d.Level == PathPolicyDiagnosticLevel.Warning &&
            d.Message.Contains("requireAbsolutePaths", StringComparison.Ordinal));
    }

    [Fact]
    public void Describe_WithBothRootsEmpty_EmitsTwoWarnings()
    {
        var diagnostics = PathPolicyDiagnostics.Describe(
            allowedInputRoots: Array.Empty<string>(),
            allowedOutputRoots: Array.Empty<string>(),
            requireAbsolutePaths: true);

        Assert.Equal(2, diagnostics.Count(d => d.Level == PathPolicyDiagnosticLevel.Warning));
    }
}
