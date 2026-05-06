using System;
using System.Diagnostics;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

internal static class TestProcessRunner
{
    public static Task<ProcessRunResult> RunAppAsync(
        string settingsPath,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
        => RunRawAsync(CreateStartInfo(settingsPath), timeout, cancellationToken);

    public static async Task<ProcessRunResult> RunAppUntilOutputAsync(
        string settingsPath,
        TimeSpan timeout,
        string requiredOutput,
        CancellationToken cancellationToken = default)
    {
        // Linked CTS: caller cancel OR per-operation timeout share one kill path. A hung
        // child cannot outlive the test even if the caller forgets to cancel.
        using var timeoutCts = new CancellationTokenSource(timeout);
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
        var ct = linkedCts.Token;

        var startInfo = CreateStartInfo(settingsPath);
        var outputBuilder = new StringBuilder();
        var requiredOutputSeen = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var sync = new object();

        using var process = new Process
        {
            StartInfo = startInfo,
            EnableRaisingEvents = true
        };

        void AppendOutput(string? line)
        {
            if (line is null)
            {
                return;
            }

            lock (sync)
            {
                outputBuilder.AppendLine(line);
                if (outputBuilder.ToString().Contains(requiredOutput, StringComparison.Ordinal))
                {
                    requiredOutputSeen.TrySetResult();
                }
            }
        }

        process.OutputDataReceived += (_, eventArgs) => AppendOutput(eventArgs.Data);
        process.ErrorDataReceived += (_, eventArgs) => AppendOutput(eventArgs.Data);

        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        using var registration = ct.Register(() => TryKillProcess(process));

        var waitForExitTask = process.WaitForExitAsync();
        var completedTask = await Task.WhenAny(requiredOutputSeen.Task, waitForExitTask).ConfigureAwait(false);

        if (completedTask == requiredOutputSeen.Task)
        {
            // Required output arrived — kill the child and wait for it to settle so the
            // test does not leave a zombie behind when it returns.
            TryKillProcess(process);
            await waitForExitTask.ConfigureAwait(false);
            return new ProcessRunResult(process.ExitCode, outputBuilder.ToString());
        }

        if (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException($"The application did not reach the expected output within {timeout}.");
        }

        cancellationToken.ThrowIfCancellationRequested();

        return new ProcessRunResult(process.ExitCode, outputBuilder.ToString());
    }

    /// <summary>
    /// Run an arbitrary process to completion or kill it on cancellation/timeout. Drains
    /// stdout and stderr concurrently with the wait so a child that fills its stderr pipe
    /// buffer (~64 KB on macOS) cannot deadlock at exit.
    /// </summary>
    public static async Task<ProcessRunResult> RunRawAsync(
        ProcessStartInfo startInfo,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(startInfo);

        startInfo.RedirectStandardOutput = true;
        startInfo.RedirectStandardError = true;
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;

        using var timeoutCts = new CancellationTokenSource(timeout);
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
        var ct = linkedCts.Token;

        using var process = new Process { StartInfo = startInfo };
        process.Start();

        using var registration = ct.Register(() => TryKillProcess(process));

        var stdOutTask = process.StandardOutput.ReadToEndAsync(ct);
        var stdErrTask = process.StandardError.ReadToEndAsync(ct);

        try
        {
            await process.WaitForExitAsync(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            await DrainSafeAsync(stdOutTask, stdErrTask).ConfigureAwait(false);
            throw new TimeoutException($"The application did not finish within {timeout}.");
        }

        var stdOut = await stdOutTask.ConfigureAwait(false);
        var stdErr = await stdErrTask.ConfigureAwait(false);
        var combined = new StringBuilder();
        combined.Append(stdOut);
        combined.Append(stdErr);
        return new ProcessRunResult(process.ExitCode, combined.ToString());
    }

    private static async Task DrainSafeAsync(Task<string> stdOut, Task<string> stdErr)
    {
        try { await stdOut.ConfigureAwait(false); } catch { }
        try { await stdErr.ConfigureAwait(false); } catch { }
    }

    private static ProcessStartInfo CreateStartInfo(string settingsPath)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "dotnet",
            WorkingDirectory = TestProjectPaths.RepositoryRoot,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        startInfo.ArgumentList.Add("run");
        startInfo.ArgumentList.Add("--project");
        startInfo.ArgumentList.Add(TestProjectPaths.AppProjectPath);
        startInfo.ArgumentList.Add("--no-build");
        startInfo.ArgumentList.Add("-c");
        startInfo.ArgumentList.Add("Debug");
        startInfo.Environment["TRANSCRIPTION_SETTINGS_PATH"] = settingsPath;

        return startInfo;
    }

    private static void TryKillProcess(Process process)
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
            // The process may already be gone when cleanup runs.
        }
    }
}

internal sealed record ProcessRunResult(int ExitCode, string Output);
