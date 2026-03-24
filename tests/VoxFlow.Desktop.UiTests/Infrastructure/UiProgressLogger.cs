namespace VoxFlow.Desktop.UiTests.Infrastructure;

internal static class UiProgressLogger
{
    private static readonly object Sync = new();
    private static readonly string? ProgressLogPath = Environment.GetEnvironmentVariable("VOXFLOW_DESKTOP_UI_PROGRESS_LOG");

    public static void Write(string message)
    {
        var line = $"[{DateTimeOffset.Now:HH:mm:ss}] {message}";

        lock (Sync)
        {
            Console.WriteLine(line);
            Console.Out.Flush();

            if (string.IsNullOrWhiteSpace(ProgressLogPath))
            {
                return;
            }

            var directory = Path.GetDirectoryName(ProgressLogPath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            File.AppendAllText(ProgressLogPath, line + Environment.NewLine);
        }
    }
}
