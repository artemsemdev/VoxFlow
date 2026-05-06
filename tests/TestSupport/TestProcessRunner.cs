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
        // Per-operation timeout linked with the caller token so cancellation OR timeout
        // both lead to the same kill-on-cancel codepath; a hung child cannot outlive the
        // test even if the caller forgets to cancel.
        using var timeoutCts = new CancellationTokenSource(timeout);
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);
        var ct = linkedCts.Token;

        var startInfo = CreateStartInfo(settingsPath);
        var outputBuilder = new StringBuilder();
        // Complete as soon as a known milestone appears in output. This keeps tests
        // focused on the stage they care about and avoids unnecessary waits.
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
                // Match against the accumulated output so tests can look for text that
                // may span stdout and stderr ordering differences.
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
            // Required output arrived before exit — kill the child and wait for it to settle so
            // the test does not leave a zombie behind when it returns.
            TryKillProcess(process);
            await waitForExitTask.ConfigureAwait(false);
            return new ProcessRunResult(process.ExitCode, outputBuilder.ToString());
        }

        // Process exited on its own. If that was via the timeout/cancel kill path, surface
        // the right exception; otherwise return the natural exit.
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
    /// buffer (~64 KB on macOS) cannot deadlock at exit. Public so cancellation behaviour
    /// can be exercised in isolation.
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

        // Caller cancel OR per-operation timeout fires the same kill path; HasExited race
        // is swallowed as in DefaultProcessLauncher.
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
        // Stream reads were started with the linked token; after Kill they may surface
        // OperationCanceledException or simply complete with whatever was buffered. Either
        // way, await both so the Tasks are observed (otherwise unobserved-task-exception
        // shows up later) and any pipe FDs are released here, not at GC time.
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

        // Run the real app entry point with a test-owned settings file so the
        // end-to-end tests exercise the same startup path as production.
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
                // Cleanup is best-effort here. The caller already has the signal it needs.
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
