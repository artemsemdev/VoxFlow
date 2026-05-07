#nullable enable
using System.Collections.Generic;

namespace VoxFlow.McpServer.Configuration;

/// <summary>
/// Configuration options for the MCP server, loaded from the <c>mcp</c> section.
/// </summary>
public sealed class McpOptions
{
    public bool Enabled { get; set; } = true;
    public string Transport { get; set; } = "stdio";
    public string ServerName { get; set; } = "voxflow";
    public string ServerVersion { get; set; } = "1.0.0";
    public bool AllowBatch { get; set; } = true;
    public List<string> AllowedInputRoots { get; set; } = new();
    public List<string> AllowedOutputRoots { get; set; } = new();
    public int MaxBatchFiles { get; set; } = 100;
    public bool RequireAbsolutePaths { get; set; } = true;

    /// <summary>
    /// Grace period (in seconds) the host waits for in-flight tool invocations
    /// to complete on SIGINT / SIGTERM before forcefully terminating. Mapped to
    /// <see cref="Microsoft.Extensions.Hosting.HostOptions.ShutdownTimeout"/>
    /// in <c>Program.cs</c>. Default 5 s — matches the .NET host default.
    /// </summary>
    public int ShutdownGracePeriodSeconds { get; set; } = 5;

    public McpResourceOptions Resources { get; set; } = new();
    public McpPromptOptions Prompts { get; set; } = new();
    public McpLoggingOptions Logging { get; set; } = new();
}

/// <summary>
/// Controls whether MCP resources are exposed to the client.
/// </summary>
public sealed class McpResourceOptions
{
    public bool Enabled { get; set; } = true;
    public bool ExposeLastRun { get; set; } = true;
}

/// <summary>
/// Controls whether predefined MCP prompts are exposed to the client.
/// </summary>
public sealed class McpPromptOptions
{
    public bool Enabled { get; set; } = true;
}

/// <summary>
/// Captures the intended MCP host logging configuration.
/// </summary>
public sealed class McpLoggingOptions
{
    public string MinimumLevel { get; set; } = "Information";
    public bool WriteToStdErr { get; set; } = true;
    public bool WriteToFile { get; set; }
    public string? LogFilePath { get; set; }
}
