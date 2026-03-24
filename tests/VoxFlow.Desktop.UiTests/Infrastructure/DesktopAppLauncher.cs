using System.Diagnostics;

namespace VoxFlow.Desktop.UiTests.Infrastructure;

internal sealed class DesktopAppLauncher : IAsyncDisposable
{
    private readonly StreamWriter _logWriter;

    private DesktopAppLauncher(StreamWriter logWriter)
    {
        _logWriter = logWriter;
    }

    public string ProcessName => RepositoryLayout.DesktopProcessName;

    public static async Task<DesktopAppLauncher> StartAsync(string appLogPath, CancellationToken cancellationToken)
    {
        EnsureDesktopAppIsNotAlreadyRunning();

        var directory = Path.GetDirectoryName(appLogPath)
            ?? throw new InvalidOperationException("App log path must have a parent directory.");
        Directory.CreateDirectory(directory);

        var logWriter = new StreamWriter(File.Open(appLogPath, FileMode.Create, FileAccess.Write, FileShare.Read))
        {
            AutoFlush = true
        };

        await logWriter.WriteLineAsync(
            $"Launching app bundle '{RepositoryLayout.DesktopAppBundlePath}' at {DateTimeOffset.UtcNow:O}");

        var openOutput = await CommandRunner.RunCheckedAsync(
            "open",
            ["-n", RepositoryLayout.DesktopAppBundlePath],
            cancellationToken: cancellationToken,
            timeout: TimeSpan.FromSeconds(30));

        if (!string.IsNullOrWhiteSpace(openOutput))
        {
            await logWriter.WriteLineAsync($"[open] {openOutput.Trim()}");
        }

        await logWriter.WriteLineAsync(
            $"Launch command finished for process name '{RepositoryLayout.DesktopProcessName}' at {DateTimeOffset.UtcNow:O}");
        return new DesktopAppLauncher(logWriter);
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            foreach (var process in Process.GetProcessesByName(RepositoryLayout.DesktopProcessName))
            {
                try
                {
                    process.Kill(entireProcessTree: true);
                    await process.WaitForExitAsync();
                }
                finally
                {
                    process.Dispose();
                }
            }
        }
        catch
        {
            // Best-effort cleanup is enough for GUI test teardown.
        }

        await _logWriter.WriteLineAsync($"Stopped process '{RepositoryLayout.DesktopProcessName}' at {DateTimeOffset.UtcNow:O}");
        await _logWriter.DisposeAsync();
    }

    private static void EnsureDesktopAppIsNotAlreadyRunning()
    {
        if (Process.GetProcessesByName(RepositoryLayout.DesktopProcessName).Length > 0)
        {
            throw new InvalidOperationException(
                "VoxFlow.Desktop is already running. Close the app before running the real UI automation tests.");
        }
    }
}
