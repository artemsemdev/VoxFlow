#nullable enable
using System.Collections.Generic;
using System.Linq;
using Microsoft.Extensions.DependencyInjection;
using ModelContextProtocol.Server;
using VoxFlow.McpServer.Configuration;
using Xunit;

public sealed class McpServerConfiguratorTests
{
    private const string ResourceTool = "get_effective_config";
    private const string CoreTool = "transcribe_file";

    private static HashSet<string> ToolNames(McpOptions options)
    {
        var services = new ServiceCollection();
        McpServerConfigurator.ApplyCapabilities(services.AddMcpServer(), options);
        return services.BuildServiceProvider()
            .GetServices<McpServerTool>()
            .Select(t => t.ProtocolTool.Name)
            .ToHashSet();
    }

    private static HashSet<string> PromptNames(McpOptions options)
    {
        var services = new ServiceCollection();
        McpServerConfigurator.ApplyCapabilities(services.AddMcpServer(), options);
        return services.BuildServiceProvider()
            .GetServices<McpServerPrompt>()
            .Select(p => p.ProtocolPrompt.Name)
            .ToHashSet();
    }

    [Fact]
    public void CoreTranscriptionTools_AreAlwaysRegistered()
    {
        var tools = ToolNames(new McpOptions { Prompts = { Enabled = false }, Resources = { Enabled = false } });
        Assert.Contains(CoreTool, tools);
    }

    [Fact]
    public void ResourceInspectionTool_Registered_WhenResourcesEnabled()
    {
        var tools = ToolNames(new McpOptions { Resources = { Enabled = true } });
        Assert.Contains(ResourceTool, tools);
    }

    [Fact]
    public void ResourceInspectionTool_NotRegistered_WhenResourcesDisabled()
    {
        var tools = ToolNames(new McpOptions { Resources = { Enabled = false } });
        Assert.DoesNotContain(ResourceTool, tools);
        // Disabling resources must not take the core tools down with it.
        Assert.Contains(CoreTool, tools);
    }

    [Fact]
    public void Prompts_Registered_WhenPromptsEnabled()
    {
        var prompts = PromptNames(new McpOptions { Prompts = { Enabled = true } });
        Assert.NotEmpty(prompts);
    }

    [Fact]
    public void Prompts_NotRegistered_WhenPromptsDisabled()
    {
        var prompts = PromptNames(new McpOptions { Prompts = { Enabled = false } });
        Assert.Empty(prompts);
    }
}
