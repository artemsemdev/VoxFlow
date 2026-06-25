#nullable enable
using System;

namespace VoxFlow.McpServer.Configuration;

/// <summary>
/// Thrown at startup when the <c>mcp</c> configuration section contains a value
/// that is not supported or is internally inconsistent. The message is meant to
/// be read by an operator, so it names the offending setting and the accepted
/// values — and never echoes secrets.
/// </summary>
public sealed class McpConfigurationException : Exception
{
    public McpConfigurationException(string message)
        : base(message)
    {
    }
}
