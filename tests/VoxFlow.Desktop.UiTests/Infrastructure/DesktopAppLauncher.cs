using System.Diagnostics;
using System.Text;

namespace VoxFlow.Desktop.UiTests.Infrastructure;

internal sealed class DesktopAppLauncher : IAsyncDisposable
{
    private readonly Process _process;
    private readonly StreamWriter _logWriter;
    private readonly Task _stdoutPump;
    private readonly Task _stderrPump;

    private DesktopAppLauncher(Process process, StreamWriter logWriter, Task stdoutPump, Task stderrPump)
    {
        _process = process;
        _logWriter = logWriter;
        _stdoutPump = stdoutPump;
        _stderrPump = stderrPump;
    }

    public int ProcessId => _process.Id;

    public static async Task<DesktopAppLauncher> StartAsync(string appLogPath, CancellationToken cancellationToken)
    {
        EnsureDesktopAppIsNotAlreadyRunning();

        var startInfo = new ProcessStartInfo
        {
            FileName = RepositoryLayout.DesktopExecutablePath,
            WorkingDirectory = Path.GetDirectoryName(RepositoryLayout.DesktopExecutablePath)
                ?? RepositoryLayout.RepositoryRoot,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        };

        var process = new Process { StartInfo = startInfo };
        if (!process.Start())
        {
            throw new InvalidOperationException("Failed to start the VoxFlow Desktop app process.");
        }

        var directory = Path.GetDirectoryName(appLogPath)
            ?? throw new InvalidOperationException("App log path must have a parent directory.");
        Directory.CreateDirectory(directory);

        var logWriter = new StreamWriter(File.Open(appLogPath, FileMode.Create, FileAccess.Write, FileShare.Read))
        {
            AutoFlush = true
        };

        var stdoutPump = PumpStreamAsync(process.StandardOutput, logWriter, "stdout", cancellationToken);
        var stderrPump = PumpStreamAsync(process.StandardError, logWriter, "stderr", cancellationToken);

        await logWriter.WriteLineAsync($"Started VoxFlow.Desktop pid={process.Id} at {DateTimeOffset.UtcNow:O}");
        return new DesktopAppLauncher(process, logWriter, stdoutPump, stderrPump);
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            if (!_process.HasExited)
            {
                _process.Kill(entireProcessTree: true);
                await _process.WaitForExitAsync();
            }
        }
        catch
        {
            // Best-effort cleanup is enough for GUI test teardown.
        }

        try
        {
            await Task.WhenAll(_stdoutPump, _stderrPump);
        }
        catch
        {
            // Ignore log pump shutdown races during forced process termination.
        }

        await _logWriter.DisposeAsync();
        _process.Dispose();
    }

    private static void EnsureDesktopAppIsNotAlreadyRunning()
    {
        if (Process.GetProcessesByName("VoxFlow.Desktop").Length > 0)
        {
            throw new InvalidOperationException(
                "VoxFlow.Desktop is already running. Close the app before running the real UI automation tests.");
        }
    }

    private static async Task PumpStreamAsync(
        StreamReader reader,
        StreamWriter logWriter,
        string streamName,
        CancellationToken cancellationToken)
    {
        while (!reader.EndOfStream)
        {
            var line = await reader.ReadLineAsync(cancellationToken);
            if (line is not null)
            {
                await logWriter.WriteLineAsync($"[{streamName}] {line}");
            }
        }
    }
}
