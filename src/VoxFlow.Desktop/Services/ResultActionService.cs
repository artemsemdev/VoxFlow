using System.Diagnostics;

namespace VoxFlow.Desktop.Services;

public interface IResultActionService
{
    Task CopyTextAsync(string text, CancellationToken cancellationToken = default);

    Task OpenResultFolderAsync(string resultFilePath, CancellationToken cancellationToken = default);
}

public sealed class ResultActionService : IResultActionService
{
    public Task CopyTextAsync(string text, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            throw new InvalidOperationException("Transcript text is unavailable.");
        }

        return MainThread.InvokeOnMainThreadAsync(async () =>
        {
            await Clipboard.Default.SetTextAsync(text);
            return true;
        });
    }

    // 10s is generous for /usr/bin/open returning after handing the path to Finder.
    // The hard cap exists so a stuck launch service or a broken Finder cannot block the
    // UI thread that awaits this method indefinitely.
    private static readonly TimeSpan OpenFolderTimeout = TimeSpan.FromSeconds(10);

    public async Task OpenResultFolderAsync(string resultFilePath, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(resultFilePath))
        {
            throw new InvalidOperationException("Result location is unavailable.");
        }

        var fullResultPath = Path.GetFullPath(resultFilePath);
        var directory = Path.GetDirectoryName(fullResultPath);
        if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory))
        {
            throw new InvalidOperationException("Result folder is unavailable.");
        }

        using var timeoutCts = new CancellationTokenSource(OpenFolderTimeout);
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
        var ct = linkedCts.Token;

        using var process = Process.Start(CreateOpenFolderProcessStartInfo(directory))
            ?? throw new InvalidOperationException("Could not start Finder.");

        // Kill the launcher process if the caller cancels or the per-operation timeout fires.
        // /usr/bin/open is short-lived in normal use, but this guards against a stuck Launch
        // Services handoff blocking the UI await indefinitely.
        using var registration = ct.Register(() =>
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                }
            }
            catch
            {
                // Process may have exited between HasExited check and Kill; swallow.
            }
        });

        // Drain both streams concurrently with the wait. /usr/bin/open is small, but a
        // child that fills the stderr pipe buffer (~64 KB on macOS) would otherwise block
        // at exit waiting for a reader — the same anti-pattern flagged in #40.
        var stdOutTask = process.StandardOutput.ReadToEndAsync(ct);
        var stdErrTask = process.StandardError.ReadToEndAsync(ct);

        try
        {
            await process.WaitForExitAsync(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            throw new InvalidOperationException(
                $"Finder did not return within {OpenFolderTimeout.TotalSeconds:0}s and was terminated.");
        }

        var stdOut = await stdOutTask.ConfigureAwait(false);
        var stdErr = await stdErrTask.ConfigureAwait(false);

        if (process.ExitCode == 0)
        {
            return;
        }

        var detail = string.IsNullOrWhiteSpace(stdErr) ? stdOut : stdErr;
        throw new InvalidOperationException(
            string.IsNullOrWhiteSpace(detail)
                ? $"Finder exited with code {process.ExitCode}."
                : detail.Trim());
    }

    private static ProcessStartInfo CreateOpenFolderProcessStartInfo(string directory)
    {
        var startInfo = new ProcessStartInfo("/usr/bin/open")
        {
            UseShellExecute = false,
            RedirectStandardError = true,
            RedirectStandardOutput = true
        };

        startInfo.ArgumentList.Add(directory);
        return startInfo;
    }
}
