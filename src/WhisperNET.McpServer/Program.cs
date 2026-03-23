#nullable enable
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using ModelContextProtocol;
using WhisperNET.McpServer.Configuration;
using WhisperNET.McpServer.Prompts;
using WhisperNET.McpServer.Resources;
using WhisperNET.McpServer.Tools;

// CRITICAL: In stdio MCP mode, stdout is reserved for protocol frames.
// Redirect all Console.Out writes to stderr so existing services that use
// Console.WriteLine do not corrupt the MCP protocol stream.
Console.SetOut(Console.Error);

var builder = Host.CreateApplicationBuilder(args);

// Load MCP-specific configuration.
var mcpSection = builder.Configuration.GetSection("mcp");
builder.Services.Configure<McpOptions>(mcpSection);

// Register application facades.
builder.Services.AddSingleton<IPathPolicy>(sp =>
{
    var mcpOptions = new McpOptions();
    mcpSection.Bind(mcpOptions);
    return new PathPolicy(
        mcpOptions.AllowedInputRoots,
        mcpOptions.AllowedOutputRoots,
        mcpOptions.RequireAbsolutePaths);
});

builder.Services.AddSingleton<IStartupValidationFacade, StartupValidationFacade>();
builder.Services.AddSingleton<ITranscriptionFacade, TranscriptionFacade>();
builder.Services.AddSingleton<IModelInspectionFacade, ModelInspectionFacade>();
builder.Services.AddSingleton<ILanguageInfoFacade, LanguageInfoFacade>();
builder.Services.AddSingleton<ITranscriptReaderFacade, TranscriptReaderFacade>();

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
