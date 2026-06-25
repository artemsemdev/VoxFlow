#nullable enable
using Microsoft.Extensions.DependencyInjection;
using ModelContextProtocol.Server;
using VoxFlow.McpServer.Prompts;
using VoxFlow.McpServer.Resources;
using VoxFlow.McpServer.Tools;

namespace VoxFlow.McpServer.Configuration;

/// <summary>
/// Applies the MCP capability toggles in <see cref="McpOptions"/> to the server
/// builder. Capabilities are registered explicitly (not by blanket assembly
/// scanning) so that a disabled toggle genuinely keeps the capability out of the
/// server — an MCP client never sees a tool or prompt the operator turned off.
/// </summary>
internal static class McpServerConfigurator
{
    public static IMcpServerBuilder ApplyCapabilities(IMcpServerBuilder builder, McpOptions options)
    {
        System.ArgumentNullException.ThrowIfNull(builder);
        System.ArgumentNullException.ThrowIfNull(options);

        // Core transcription tools are the reason the server exists; always on.
        builder.WithTools<WhisperMcpTools>();

        // Read-only configuration-inspection tool. Gated by resources.enabled so
        // operators can stop the server from disclosing the effective config.
        if (options.Resources.Enabled)
        {
            builder.WithTools<WhisperMcpResourceTools>();
        }

        // Guided MCP prompts. Gated by prompts.enabled.
        if (options.Prompts.Enabled)
        {
            builder.WithPrompts<WhisperMcpPrompts>();
        }

        return builder;
    }
}
