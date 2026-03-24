using System.Runtime.InteropServices;
using VoxFlow.Core.Services;
using Xunit;

namespace VoxFlow.Core.Tests;

public sealed class WhisperRuntimeFailureFormatterTests
{
    [Fact]
    public void GetFriendlyMessage_WhenIntelMacCatalystRuntimeIsUnsupported_ReturnsActionableGuidance()
    {
        var message = WhisperRuntimeFailureFormatter.GetFriendlyMessage(
            "Unsupported OS Version",
            Architecture.X64,
            isMacCatalyst: true);

        Assert.Contains("Intel Macs", message);
        Assert.Contains("VoxFlow CLI", message);
        Assert.Contains("Apple Silicon", message);
    }

    [Fact]
    public void TryGetFriendlyMessage_WhenPlatformDoesNotMatch_ReturnsFalse()
    {
        var handled = WhisperRuntimeFailureFormatter.TryGetFriendlyMessage(
            "Unsupported OS Version",
            Architecture.X64,
            isMacCatalyst: false,
            out var message);

        Assert.False(handled);
        Assert.Equal(string.Empty, message);
    }
}
