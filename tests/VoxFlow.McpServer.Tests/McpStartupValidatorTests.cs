#nullable enable
using Microsoft.Extensions.Logging;
using VoxFlow.McpServer.Configuration;
using Xunit;

public sealed class McpStartupValidatorTests
{
    [Fact]
    public void Validate_DefaultOptions_DoesNotThrow()
    {
        McpStartupValidator.Validate(new McpOptions());
    }

    [Theory]
    [InlineData("stdio")]
    [InlineData("STDIO")]
    [InlineData("  stdio  ")]
    public void Validate_AcceptsSupportedTransport(string transport)
    {
        var options = new McpOptions { Transport = transport };
        McpStartupValidator.Validate(options);
    }

    [Theory]
    [InlineData("http")]
    [InlineData("HTTP")]
    [InlineData("tcp")]
    [InlineData("sse")]
    [InlineData("")]
    public void Validate_RejectsUnsupportedTransport_WithActionableMessage(string transport)
    {
        var options = new McpOptions { Transport = transport };

        var ex = Assert.Throws<McpConfigurationException>(() => McpStartupValidator.Validate(options));
        Assert.Contains("transport", ex.Message, System.StringComparison.OrdinalIgnoreCase);
        Assert.Contains("stdio", ex.Message, System.StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("Trace")]
    [InlineData("information")]
    [InlineData("Warning")]
    [InlineData("None")]
    public void Validate_AcceptsValidMinimumLevel(string level)
    {
        var options = new McpOptions();
        options.Logging.MinimumLevel = level;
        McpStartupValidator.Validate(options);
    }

    [Theory]
    [InlineData("Verbose")]
    [InlineData("loud")]
    [InlineData("99")]
    [InlineData("")]
    public void Validate_RejectsInvalidMinimumLevel_WithActionableMessage(string level)
    {
        var options = new McpOptions();
        options.Logging.MinimumLevel = level;

        var ex = Assert.Throws<McpConfigurationException>(() => McpStartupValidator.Validate(options));
        Assert.Contains("minimumLevel", ex.Message, System.StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Validate_WriteToFileWithoutPath_Throws()
    {
        var options = new McpOptions();
        options.Logging.WriteToFile = true;
        options.Logging.LogFilePath = "   ";

        var ex = Assert.Throws<McpConfigurationException>(() => McpStartupValidator.Validate(options));
        Assert.Contains("logFilePath", ex.Message, System.StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Validate_WriteToFileWithPath_DoesNotThrow()
    {
        var options = new McpOptions();
        options.Logging.WriteToFile = true;
        options.Logging.LogFilePath = "/var/log/voxflow-mcp.log";
        McpStartupValidator.Validate(options);
    }

    [Fact]
    public void Validate_WriteToFileFalse_IgnoresEmptyPath()
    {
        var options = new McpOptions();
        options.Logging.WriteToFile = false;
        options.Logging.LogFilePath = "";
        McpStartupValidator.Validate(options);
    }

    [Theory]
    [InlineData("Information", LogLevel.Information)]
    [InlineData("warning", LogLevel.Warning)]
    [InlineData("TRACE", LogLevel.Trace)]
    public void TryParseLogLevel_ParsesKnownLevels(string value, LogLevel expected)
    {
        Assert.True(McpStartupValidator.TryParseLogLevel(value, out var level));
        Assert.Equal(expected, level);
    }

    [Theory]
    [InlineData("nope")]
    [InlineData("99")]
    [InlineData(null)]
    public void TryParseLogLevel_RejectsUnknown(string? value)
    {
        Assert.False(McpStartupValidator.TryParseLogLevel(value, out _));
    }
}
