#if DEBUG && MACCATALYST
namespace VoxFlow.Desktop.Automation;

internal static class DesktopUiAutomationPaths
{
    public static string RootDirectory =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Library",
            "Application Support",
            "VoxFlow",
            "ui-automation");

    public static string SessionFilePath => Path.Combine(RootDirectory, "active-session.json");

    public static string RequestsDirectory => Path.Combine(RootDirectory, "requests");

    public static string ResponsesDirectory => Path.Combine(RootDirectory, "responses");

    public static string BridgeLogPath => Path.Combine(RootDirectory, "bridge.log");

    public static string ReadyFilePath(string sessionId)
        => Path.Combine(RootDirectory, $"ready-{sessionId}.json");

    public static string RequestFilePath(string sessionId, string commandId)
        => Path.Combine(RequestsDirectory, $"request-{sessionId}-{commandId}.json");

    public static string ResponseFilePath(string sessionId, string commandId)
        => Path.Combine(ResponsesDirectory, $"response-{sessionId}-{commandId}.json");
}
#endif
