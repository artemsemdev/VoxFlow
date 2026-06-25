#nullable enable
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using ModelContextProtocol;
using VoxFlow.Core.DependencyInjection;
using VoxFlow.Core.Logging;
using VoxFlow.McpServer.Configuration;
using VoxFlow.McpServer.Prompts;
using VoxFlow.McpServer.Security;
using VoxFlow.McpServer.Tools;

// CRITICAL: In stdio MCP mode, stdout is reserved for protocol frames.
// Redirect incidental Console.Out writes to stderr so they cannot corrupt the
// MCP protocol stream.
Console.SetOut(Console.Error);

var builder = Host.CreateApplicationBuilder(args);

// Single source of truth for McpOptions. The Configure<McpOptions> below makes
// the same data available to anything that resolves IOptions<McpOptions> from
// DI; the local instance below is only used for the AddMcpServer lambda
// (which has no IServiceProvider hook) and for the host shutdown timeout.
var mcpSection = builder.Configuration.GetSection("mcp");
var mcpOptions = mcpSection.Get<McpOptions>() ?? new McpOptions();
builder.Services.Configure<McpOptions>(mcpSection);
builder.Logging.ClearProviders();
builder.Logging.AddProvider(new TextWriterLoggerProvider(Console.Error));

// Map the configured grace period onto the .NET host's shutdown timeout so
// hosted services (including the MCP transport) get a chance to drain
// in-flight work before the process exits.
builder.Services.Configure<HostOptions>(host =>
    host.ShutdownTimeout = TimeSpan.FromSeconds(Math.Max(0, mcpOptions.ShutdownGracePeriodSeconds)));

// Register Core services via DI extension.
builder.Services.AddVoxFlowCore();

// Register MCP-specific path policy. Resolved via IOptions<McpOptions> so it
// stays in sync with the single Configure<McpOptions> registration above.
builder.Services.AddSingleton<IPathPolicy>(sp =>
{
    var opts = sp.GetRequiredService<IOptions<McpOptions>>().Value;
    return new PathPolicy(
        opts.AllowedInputRoots,
        opts.AllowedOutputRoots,
        opts.RequireAbsolutePaths);
});

// Configure MCP server with stdio transport. AddMcpServer's options callback
// has no IServiceProvider parameter, so it reads the local mcpOptions
// captured via closure — the only consumer of the local instance.
builder.Services
    .AddMcpServer(options =>
    {
        options.ServerInfo = new()
        {
            Name = mcpOptions.ServerName,
            Version = mcpOptions.ServerVersion
        };
    })
    .WithStdioServerTransport()
    .WithToolsFromAssembly(typeof(WhisperMcpTools).Assembly)
    .WithPromptsFromAssembly(typeof(WhisperMcpPrompts).Assembly);

var app = builder.Build();
var logger = app.Services
    .GetRequiredService<ILoggerFactory>()
    .CreateLogger("VoxFlow.McpServer");

// Make the effective filesystem boundary obvious at startup. Empty allow-lists
// mean the server can touch any path the user can — operators must see that
// loudly (on stderr; stdout is the MCP protocol stream) rather than discover it
// the hard way. See docs/deployment/mcp-server-security.md.
foreach (var diagnostic in PathPolicyDiagnostics.Describe(
             mcpOptions.AllowedInputRoots,
             mcpOptions.AllowedOutputRoots,
             mcpOptions.RequireAbsolutePaths))
{
    if (diagnostic.Level == PathPolicyDiagnosticLevel.Warning)
    {
        logger.LogWarning("{PathPolicyDiagnostic}", diagnostic.Message);
    }
    else
    {
        logger.LogInformation("{PathPolicyDiagnostic}", diagnostic.Message);
    }
}

// Surface the shutdown handoff so MCP clients (Claude Desktop, Cursor, etc.)
// see a trace instead of an abrupt close. Goes to stderr because stdout is
// reserved for the MCP protocol stream.
var lifetime = app.Services.GetRequiredService<IHostApplicationLifetime>();
lifetime.ApplicationStopping.Register(() =>
    logger.LogInformation(
        "[mcp] shutting down - waiting up to {ShutdownGracePeriodSeconds}s for in-flight tool invocations to drain.",
        mcpOptions.ShutdownGracePeriodSeconds));

await app.RunAsync();
