#nullable enable
using System;
using System.Collections.Generic;
using System.Linq;

namespace VoxFlow.McpServer.Security;

/// <summary>
/// Severity of a startup path-policy diagnostic. <see cref="Warning"/> means the
/// effective policy leaves the server more exposed than a hardened deployment.
/// </summary>
internal enum PathPolicyDiagnosticLevel
{
    Information,
    Warning,
}

/// <summary>
/// A single human-readable statement about the effective MCP path policy,
/// surfaced to the operator at startup.
/// </summary>
internal readonly record struct PathPolicyDiagnostic(PathPolicyDiagnosticLevel Level, string Message);

/// <summary>
/// Builds the startup diagnostics that describe the effective <see cref="PathPolicy"/>
/// configuration. The point is to make it obvious — in the server's stderr log — when
/// the MCP server is running without root restrictions, instead of failing silently
/// open. Pure and side-effect free so it can be unit tested; the host is responsible
/// for routing the results to a logger.
/// </summary>
internal static class PathPolicyDiagnostics
{
    public static IReadOnlyList<PathPolicyDiagnostic> Describe(
        IReadOnlyList<string> allowedInputRoots,
        IReadOnlyList<string> allowedOutputRoots,
        bool requireAbsolutePaths)
    {
        ArgumentNullException.ThrowIfNull(allowedInputRoots);
        ArgumentNullException.ThrowIfNull(allowedOutputRoots);

        var diagnostics = new List<PathPolicyDiagnostic>
        {
            DescribeRoots("input", "allowedInputRoots", allowedInputRoots),
            DescribeRoots("output", "allowedOutputRoots", allowedOutputRoots),
        };

        if (!requireAbsolutePaths)
        {
            diagnostics.Add(new PathPolicyDiagnostic(
                PathPolicyDiagnosticLevel.Warning,
                "MCP path policy: requireAbsolutePaths is disabled. Relative paths will be " +
                "resolved against the server working directory, which is hard to reason about. " +
                "Enable requireAbsolutePaths unless you have a specific reason not to."));
        }

        return diagnostics;
    }

    private static PathPolicyDiagnostic DescribeRoots(
        string kind,
        string settingName,
        IReadOnlyList<string> roots)
    {
        var configured = roots.Where(r => !string.IsNullOrWhiteSpace(r)).ToArray();

        if (configured.Length == 0)
        {
            return new PathPolicyDiagnostic(
                PathPolicyDiagnosticLevel.Warning,
                $"MCP {kind} access is UNRESTRICTED: no {settingName} configured. Any absolute path " +
                $"the server user can access is allowed. Configure {settingName} before exposing this " +
                "server to an MCP client.");
        }

        return new PathPolicyDiagnostic(
            PathPolicyDiagnosticLevel.Information,
            $"MCP {kind} roots ({configured.Length}): {string.Join(", ", configured)}");
    }
}
