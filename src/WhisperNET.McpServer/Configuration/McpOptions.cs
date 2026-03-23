#nullable enable
using System.Collections.Generic;

namespace WhisperNET.McpServer.Configuration;

/// <summary>
/// Configuration options for the MCP server, loaded from appsettings.json "mcp" section.
/// </summary>
public sealed class McpOptions
{
    public bool Enabled { get; set; } = true;
    public string Transport { get; set; } = "stdio";
    public string ServerName { get; set; } = "whispernet";
    public string ServerVersion { get; set; } = "1.0.0";
    public bool AllowBatch { get; set; } = true;
    public List<string> AllowedInputRoots { get; set; } = new();
    public List<string> AllowedOutputRoots { get; set; } = new();
    public int MaxBatchFiles { get; set; } = 100;
    public bool RequireAbsolutePaths { get; set; } = true;
    public McpResourceOptions Resources { get; set; } = new();
    public McpPromptOptions Prompts { get; set; } = new();
    public McpLoggingOptions Logging { get; set; } = new();
}

public sealed class McpResourceOptions
{
    public bool Enabled { get; set; } = true;
    public bool ExposeLastRun { get; set; } = true;
}

public sealed class McpPromptOptions
{
    public bool Enabled { get; set; } = true;
}

public sealed class McpLoggingOptions
{
    public string MinimumLevel { get; set; } = "Information";
    public bool WriteToStdErr { get; set; } = true;
    public bool WriteToFile { get; set; }
    public string? LogFilePath { get; set; }
}
