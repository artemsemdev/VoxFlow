#nullable enable
using WhisperNET.McpServer.Configuration;
using Xunit;

public sealed class McpConfigurationTests
{
    [Fact]
    public void McpOptions_DefaultValues_AreCorrect()
    {
        var options = new McpOptions();

        Assert.True(options.Enabled);
        Assert.Equal("stdio", options.Transport);
        Assert.Equal("whispernet", options.ServerName);
        Assert.Equal("1.0.0", options.ServerVersion);
        Assert.True(options.AllowBatch);
        Assert.Empty(options.AllowedInputRoots);
        Assert.Empty(options.AllowedOutputRoots);
        Assert.Equal(100, options.MaxBatchFiles);
        Assert.True(options.RequireAbsolutePaths);
    }

    [Fact]
    public void McpResourceOptions_DefaultValues_AreCorrect()
    {
        var options = new McpResourceOptions();

        Assert.True(options.Enabled);
        Assert.True(options.ExposeLastRun);
    }

    [Fact]
    public void McpPromptOptions_DefaultValues_AreCorrect()
    {
        var options = new McpPromptOptions();
        Assert.True(options.Enabled);
    }

    [Fact]
    public void McpLoggingOptions_DefaultValues_AreCorrect()
    {
        var options = new McpLoggingOptions();

        Assert.Equal("Information", options.MinimumLevel);
        Assert.True(options.WriteToStdErr);
        Assert.False(options.WriteToFile);
        Assert.Null(options.LogFilePath);
    }

    [Fact]
    public void McpOptions_CanSetCustomValues()
    {
        var options = new McpOptions
        {
            Enabled = false,
            Transport = "http",
            ServerName = "custom-server",
            ServerVersion = "2.0.0",
            AllowBatch = false,
            AllowedInputRoots = new() { "/input1", "/input2" },
            AllowedOutputRoots = new() { "/output1" },
            MaxBatchFiles = 50,
            RequireAbsolutePaths = false
        };

        Assert.False(options.Enabled);
        Assert.Equal("http", options.Transport);
        Assert.Equal("custom-server", options.ServerName);
        Assert.Equal("2.0.0", options.ServerVersion);
        Assert.False(options.AllowBatch);
        Assert.Equal(2, options.AllowedInputRoots.Count);
        Assert.Single(options.AllowedOutputRoots);
        Assert.Equal(50, options.MaxBatchFiles);
        Assert.False(options.RequireAbsolutePaths);
    }
}
