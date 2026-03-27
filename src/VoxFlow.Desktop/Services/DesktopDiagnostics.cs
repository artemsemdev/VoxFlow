using System.Text;

namespace VoxFlow.Desktop.Services;

internal static class DesktopDiagnostics
{
    private static readonly object Sync = new();
    private static bool _initialized;

    public static string LogPath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Library",
            "Application Support",
            "VoxFlow",
            "logs",
            "desktop.log");

    public static void InitializeUnhandledExceptionLogging()
    {
        lock (Sync)
        {
            if (_initialized)
            {
                return;
            }

            AppDomain.CurrentDomain.UnhandledException += (_, args) =>
            {
                if (args.ExceptionObject is Exception exception)
                {
                    LogException("AppDomain.CurrentDomain.UnhandledException", exception);
                    return;
                }

                LogMessage(
                    "AppDomain.CurrentDomain.UnhandledException",
                    args.ExceptionObject?.ToString() ?? "Unknown unhandled exception object.");
            };

            TaskScheduler.UnobservedTaskException += (_, args) =>
            {
                LogException("TaskScheduler.UnobservedTaskException", args.Exception);
                args.SetObserved();
            };

            _initialized = true;
            LogInfo("Desktop diagnostics initialized.");
        }
    }

    public static void LogInfo(string message)
        => LogMessage("Info", message);

    public static void LogException(string context, Exception exception)
    {
        ArgumentNullException.ThrowIfNull(exception);
        LogMessage(context, exception.ToString());
    }

    private static void LogMessage(string context, string message)
    {
        try
        {
            var directory = Path.GetDirectoryName(LogPath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            var builder = new StringBuilder();
            builder.Append('[')
                .Append(DateTimeOffset.UtcNow.ToString("O"))
                .Append("] ")
                .Append(context)
                .AppendLine();
            builder.AppendLine(message.Trim());
            builder.AppendLine();

            lock (Sync)
            {
                File.AppendAllText(LogPath, builder.ToString());
            }
        }
        catch
        {
            // Logging must never become another startup failure.
        }
    }
}
