using System.Diagnostics;
using System.Text;

namespace VoxFlow.Desktop.UiTests.Infrastructure;

internal static class CommandRunner
{
    public static async Task<CommandResult> RunAsync(
        string fileName,
        IReadOnlyList<string> arguments,
        string? workingDirectory = null,
        string? stdIn = null,
        CancellationToken cancellationToken = default,
        TimeSpan? timeout = null)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            WorkingDirectory = workingDirectory ?? RepositoryLayout.RepositoryRoot,
            RedirectStandardInput = stdIn is not null,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        };

        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = startInfo };
        process.Start();

        if (stdIn is not null)
        {
            await process.StandardInput.WriteAsync(stdIn.AsMemory(), cancellationToken);
            process.StandardInput.Close();
        }

        var standardOutputTask = process.StandardOutput.ReadToEndAsync();
        var standardErrorTask = process.StandardError.ReadToEndAsync();

        using var timeoutSource = timeout is null ? null : new CancellationTokenSource(timeout.Value);
        using var linkedCancellation = timeoutSource is null
            ? CancellationTokenSource.CreateLinkedTokenSource(cancellationToken)
            : CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutSource.Token);

        try
        {
            await process.WaitForExitAsync(linkedCancellation.Token);
        }
        catch (OperationCanceledException) when (timeoutSource?.IsCancellationRequested == true)
        {
            TryKillProcess(process);
            throw new TimeoutException($"Command timed out after {timeout!.Value}.");
        }
        catch
        {
            TryKillProcess(process);
            throw;
        }

        var standardOutput = await standardOutputTask;
        var standardError = await standardErrorTask;
        return new CommandResult(process.ExitCode, standardOutput, standardError);
    }

    public static async Task<string> RunCheckedAsync(
        string fileName,
        IReadOnlyList<string> arguments,
        string? workingDirectory = null,
        string? stdIn = null,
        CancellationToken cancellationToken = default,
        TimeSpan? timeout = null)
    {
        var result = await RunAsync(fileName, arguments, workingDirectory, stdIn, cancellationToken, timeout);
        if (result.ExitCode != 0)
        {
            var details = new StringBuilder();
            details.AppendLine($"Command failed: {fileName} {string.Join(" ", arguments)}");
            if (!string.IsNullOrWhiteSpace(result.StandardOutput))
            {
                details.AppendLine("stdout:");
                details.AppendLine(result.StandardOutput.Trim());
            }

            if (!string.IsNullOrWhiteSpace(result.StandardError))
            {
                details.AppendLine("stderr:");
                details.AppendLine(result.StandardError.Trim());
            }

            throw new InvalidOperationException(details.ToString().Trim());
        }

        return result.StandardOutput;
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
            // Best-effort cleanup is enough for a failed shell command.
        }
    }
}

internal sealed record CommandResult(int ExitCode, string StandardOutput, string StandardError);
