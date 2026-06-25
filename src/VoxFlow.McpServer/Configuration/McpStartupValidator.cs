#nullable enable
using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.Extensions.Logging;

namespace VoxFlow.McpServer.Configuration;

/// <summary>
/// Validates <see cref="McpOptions"/> at startup so configuration is an
/// executable contract: an option that looks supported but is silently ignored
/// is a security hazard (an operator may believe a capability is off or a
/// transport restricted when it is not). Unsupported or inconsistent values
/// fail fast with an actionable message instead of being quietly dropped.
/// </summary>
internal static class McpStartupValidator
{
    /// <summary>
    /// Transports the server actually implements. Adding HTTP/SSE/etc. is
    /// explicitly out of scope (#71) — until one is wired, configuring it must
    /// fail rather than silently fall back to stdio.
    /// </summary>
    public static readonly IReadOnlyList<string> SupportedTransports = new[] { "stdio" };

    public static void Validate(McpOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

        if (!IsSupportedTransport(options.Transport))
        {
            throw new McpConfigurationException(
                $"Unsupported mcp.transport '{options.Transport}'. " +
                $"Supported transports: {string.Join(", ", SupportedTransports)}.");
        }

        if (!TryParseLogLevel(options.Logging.MinimumLevel, out _))
        {
            throw new McpConfigurationException(
                $"Invalid mcp.logging.minimumLevel '{options.Logging.MinimumLevel}'. " +
                "Valid values: Trace, Debug, Information, Warning, Error, Critical, None.");
        }

        if (options.Logging.WriteToFile && string.IsNullOrWhiteSpace(options.Logging.LogFilePath))
        {
            throw new McpConfigurationException(
                "mcp.logging.writeToFile is true but mcp.logging.logFilePath is empty. " +
                "Set logFilePath to an absolute path or disable writeToFile.");
        }
    }

    public static bool IsSupportedTransport(string? transport)
    {
        if (string.IsNullOrWhiteSpace(transport))
        {
            return false;
        }

        return SupportedTransports.Contains(transport.Trim(), StringComparer.OrdinalIgnoreCase);
    }

    public static bool TryParseLogLevel(string? value, out LogLevel level)
    {
        level = LogLevel.None;
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        // Reject numeric strings ("3") and undefined values; only accept the
        // named LogLevel members so config stays readable.
        return Enum.TryParse(value.Trim(), ignoreCase: true, out level)
               && Enum.IsDefined(level)
               && !int.TryParse(value.Trim(), out _);
    }
}
