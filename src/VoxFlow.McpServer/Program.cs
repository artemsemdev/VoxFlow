#nullable enable
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using ModelContextProtocol;
using VoxFlow.Core.DependencyInjection;
using VoxFlow.McpServer.Configuration;
using VoxFlow.McpServer.Prompts;
using VoxFlow.McpServer.Security;
using VoxFlow.McpServer.Tools;

// CRITICAL: In stdio MCP mode, stdout is reserved for protocol frames.
// Redirect all Console.Out writes to stderr so existing services that use
// Console.WriteLine do not corrupt the MCP protocol stream.
Console.SetOut(Console.Error);

var builder = Host.CreateApplicationBuilder(args);

// Load MCP-specific configuration.
var mcpSection = builder.Configuration.GetSection("mcp");
builder.Services.Configure<McpOptions>(mcpSection);

// Register Core services via DI extension.
builder.Services.AddVoxFlowCore();

// Register MCP-specific path policy.
builder.Services.AddSingleton<IPathPolicy>(sp =>
{
    var mcpOptions = new McpOptions();
    mcpSection.Bind(mcpOptions);
    return new PathPolicy(
        mcpOptions.AllowedInputRoots,
        mcpOptions.AllowedOutputRoots,
        mcpOptions.RequireAbsolutePaths);
});

// Configure MCP server with stdio transport.
builder.Services
    .AddMcpServer(options =>
    {
        var mcpOptions = new McpOptions();
        mcpSection.Bind(mcpOptions);

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
await app.RunAsync();
