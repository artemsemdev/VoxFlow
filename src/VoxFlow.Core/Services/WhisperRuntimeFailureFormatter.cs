using System;
using System.Runtime.InteropServices;

namespace VoxFlow.Core.Services;

/// <summary>
/// Converts low-level Whisper runtime load failures into actionable messages.
/// </summary>
internal static class WhisperRuntimeFailureFormatter
{
    private const string UnsupportedOsVersionMessage = "Unsupported OS Version";
    private const string IntelMacCatalystMessage =
        "Whisper runtime is not supported in VoxFlow Desktop on Intel Macs. " +
        "Whisper.net.Runtime 1.9.0 does not ship x64 Mac Catalyst binaries. " +
        "Use VoxFlow CLI on this machine or run VoxFlow Desktop on Apple Silicon.";

    public static string GetFriendlyMessage(Exception ex)
        => GetFriendlyMessage(ex.Message, RuntimeInformation.ProcessArchitecture, OperatingSystem.IsMacCatalyst());

    public static string GetFriendlyMessage(string? message)
        => GetFriendlyMessage(message, RuntimeInformation.ProcessArchitecture, OperatingSystem.IsMacCatalyst());

    public static bool IsFatalPlatformCompatibilityFailure(string? message)
        => TryGetFriendlyMessage(message, RuntimeInformation.ProcessArchitecture, OperatingSystem.IsMacCatalyst(), out _);

    internal static string GetFriendlyMessage(string? message, Architecture architecture, bool isMacCatalyst)
        => TryGetFriendlyMessage(message, architecture, isMacCatalyst, out var friendlyMessage)
            ? friendlyMessage
            : string.IsNullOrWhiteSpace(message)
                ? "Unknown Whisper runtime error."
                : message;

    internal static bool TryGetFriendlyMessage(
        string? message,
        Architecture architecture,
        bool isMacCatalyst,
        out string friendlyMessage)
    {
        if (architecture == Architecture.X64
            && isMacCatalyst
            && !string.IsNullOrWhiteSpace(message)
            && message.Contains(UnsupportedOsVersionMessage, StringComparison.OrdinalIgnoreCase))
        {
            friendlyMessage = IntelMacCatalystMessage;
            return true;
        }

        friendlyMessage = string.Empty;
        return false;
    }
}
