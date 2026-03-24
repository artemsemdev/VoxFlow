using System;
using System.Diagnostics;
using System.Text;
using System.Threading.Tasks;

internal static class TestProcessRunner
{
    public static async Task<ProcessRunResult> RunAppAsync(string settingsPath, TimeSpan timeout)
    {
        var startInfo = CreateStartInfo(settingsPath);

        using var process = new Process { StartInfo = startInfo };
        process.Start();

        var standardOutputTask = process.StandardOutput.ReadToEndAsync();
        var standardErrorTask = process.StandardError.ReadToEndAsync();
        var waitForExitTask = process.WaitForExitAsync();
        var completedTask = await Task.WhenAny(waitForExitTask, Task.Delay(timeout)).ConfigureAwait(false);

        if (completedTask != waitForExitTask)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch
            {
                // The process may already be gone when timeout cleanup runs.
            }

            throw new TimeoutException($"The application did not finish within {timeout}.");
        }

        var outputBuilder = new StringBuilder();
        outputBuilder.Append(await standardOutputTask.ConfigureAwait(false));
        outputBuilder.Append(await standardErrorTask.ConfigureAwait(false));

        return new ProcessRunResult(process.ExitCode, outputBuilder.ToString());
    }

    public static async Task<ProcessRunResult> RunAppUntilOutputAsync(
        string settingsPath,
        TimeSpan timeout,
        string requiredOutput)
    {
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

        var waitForExitTask = process.WaitForExitAsync();
        var completedTask = await Task.WhenAny(requiredOutputSeen.Task, waitForExitTask, Task.Delay(timeout))
            .ConfigureAwait(false);

        if (completedTask == requiredOutputSeen.Task)
        {
            TryKillProcess(process);
            await waitForExitTask.ConfigureAwait(false);
            return new ProcessRunResult(process.ExitCode, outputBuilder.ToString());
        }

        if (completedTask == waitForExitTask)
        {
            return new ProcessRunResult(process.ExitCode, outputBuilder.ToString());
        }

        TryKillProcess(process);
        await waitForExitTask.ConfigureAwait(false);
        throw new TimeoutException($"The application did not reach the expected output within {timeout}.");
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
