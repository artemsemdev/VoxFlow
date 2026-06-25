#nullable enable
using System.IO;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using ModelContextProtocol;
using VoxFlow.Core.DependencyInjection;
using VoxFlow.Core.Logging;
using VoxFlow.McpServer.Configuration;
using VoxFlow.McpServer.Security;

// CRITICAL: In stdio MCP mode, stdout is reserved for protocol frames.
// Redirect incidental Console.Out writes to stderr so they cannot corrupt the
// MCP protocol stream.
Console.SetOut(Console.Error);

var builder = Host.CreateApplicationBuilder(args);

// Single source of truth for McpOptions. The Configure<McpOptions> below makes
// the same data available to anything that resolves IOptions<McpOptions> from
// DI; the local instance below is also used for the AddMcpServer lambda (which
// has no IServiceProvider hook), startup validation, and logging setup.
var mcpSection = builder.Configuration.GetSection("mcp");
var mcpOptions = mcpSection.Get<McpOptions>() ?? new McpOptions();

// Fail fast on unsupported or inconsistent configuration BEFORE doing any work.
// An option that looks supported but is silently ignored (e.g. transport=http
// quietly using stdio) is a security hazard, so reject it with an actionable
// message instead of dropping it.
try
{
    McpStartupValidator.Validate(mcpOptions);
}
catch (McpConfigurationException ex)
{
    Console.Error.WriteLine($"[mcp] configuration error: {ex.Message}");
    return 1;
}

// Honor the master switch. An MCP client may launch the server process while it
// is disabled in config; exit cleanly rather than silently serving anyway.
if (!mcpOptions.Enabled)
{
    Console.Error.WriteLine("[mcp] disabled via mcp.enabled=false; exiting without starting the server.");
    return 0;
}

builder.Services.Configure<McpOptions>(mcpSection);

// Logging providers honor the logging.* options. stdout is reserved for the MCP
// protocol stream, so logs only ever go to stderr and/or a file — never stdout.
// minimumLevel was validated above, so the parse here always succeeds.
var minimumLevel = McpStartupValidator.TryParseLogLevel(mcpOptions.Logging.MinimumLevel, out var parsedLevel)
    ? parsedLevel
    : LogLevel.Information;
builder.Logging.ClearProviders();
if (mcpOptions.Logging.WriteToStdErr)
{
    builder.Logging.AddProvider(new TextWriterLoggerProvider(Console.Error, minimumLevel));
}

if (mcpOptions.Logging.WriteToFile)
{
    // logFilePath is a trusted operator setting and is intentionally NOT gated
    // by PathPolicy (see docs/deployment/mcp-server-security.md). Validation
    // already guaranteed it is non-empty; a failure to open it is a startup
    // error, not something to silently swallow.
    StreamWriter fileWriter;
    try
    {
        fileWriter = new StreamWriter(mcpOptions.Logging.LogFilePath!, append: true) { AutoFlush = true };
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
    {
        Console.Error.WriteLine(
            $"[mcp] configuration error: cannot open mcp.logging.logFilePath '{mcpOptions.Logging.LogFilePath}': {ex.Message}");
        return 1;
    }

    builder.Logging.AddProvider(new TextWriterLoggerProvider(fileWriter, minimumLevel));
}

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

// Configure MCP server. Transport is validated above, so stdio here can never be
// a silent fallback for an unsupported value. Tools and prompts are registered
// explicitly per the capability toggles (not by blanket assembly scanning) so a
// disabled toggle genuinely keeps the capability out of the server.
var mcpBuilder = builder.Services
    .AddMcpServer(options =>
    {
        options.ServerInfo = new()
        {
            Name = mcpOptions.ServerName,
            Version = mcpOptions.ServerVersion
        };
    })
    .WithStdioServerTransport();
McpServerConfigurator.ApplyCapabilities(mcpBuilder, mcpOptions);

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

// Surface the effective capability contract so operators can confirm what the
// running server actually exposes.
logger.LogInformation(
    "[mcp] effective config: transport=stdio, prompts={Prompts}, resources={Resources}.",
    mcpOptions.Prompts.Enabled ? "enabled" : "disabled",
    mcpOptions.Resources.Enabled ? "enabled" : "disabled");

// Surface the shutdown handoff so MCP clients (Claude Desktop, Cursor, etc.)
// see a trace instead of an abrupt close. Goes to stderr because stdout is
// reserved for the MCP protocol stream.
var lifetime = app.Services.GetRequiredService<IHostApplicationLifetime>();
lifetime.ApplicationStopping.Register(() =>
    logger.LogInformation(
        "[mcp] shutting down - waiting up to {ShutdownGracePeriodSeconds}s for in-flight tool invocations to drain.",
        mcpOptions.ShutdownGracePeriodSeconds));

await app.RunAsync();
return 0;
