using System.Diagnostics;
using System.Text;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;
using VoxFlow.Desktop.Configuration;

namespace VoxFlow.Desktop.Services;

internal sealed class DesktopCliTranscriptionService : ITranscriptionService
{
    private readonly DesktopConfigurationService _configurationService;
    private readonly ITranscriptReader _transcriptReader;

    public DesktopCliTranscriptionService(
        DesktopConfigurationService configurationService,
        ITranscriptReader transcriptReader)
    {
        _configurationService = configurationService;
        _transcriptReader = transcriptReader;
    }

    public async Task<TranscribeFileResult> TranscribeFileAsync(
        TranscribeFileRequest request,
        IProgress<ProgressUpdate>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (!DesktopCliSupport.ShouldUseCliBridge())
        {
            throw new InvalidOperationException("CLI bridge should only be used on Intel Mac Catalyst.");
        }

        var stopwatch = Stopwatch.StartNew();
        // Run the CLI against a disposable merged snapshot so per-request paths never mutate the user's settings file.
        var configurationPath = _configurationService.WriteMergedConfigurationSnapshot(
            request.ConfigurationPath,
            transcription =>
            {
                transcription["inputFilePath"] = request.InputPath;
                if (!string.IsNullOrWhiteSpace(request.ResultFilePath))
                {
                    transcription["resultFilePath"] = request.ResultFilePath;
                }
            },
            applyDesktopRuntimeOverrides: false);

        try
        {
            var options = TranscriptionOptions.LoadFromPath(configurationPath);
            progress?.Report(new ProgressUpdate(
                ProgressStage.Validating,
                0,
                stopwatch.Elapsed,
                "Running CLI transcription pipeline..."));

            var processStartInfo = CreateProcessStartInfo(configurationPath);
            using var process = new Process
            {
                StartInfo = processStartInfo
            };

            process.Start();

            using var cancellationRegistration = cancellationToken.Register(() => TryKill(process));

            var standardOutput = new StringBuilder();
            var standardError = new StringBuilder();

            var standardOutputTask = PumpReaderAsync(
                process.StandardOutput,
                line => AppendOutputLine(line, standardOutput, progress),
                cancellationToken);
            var standardErrorTask = PumpReaderAsync(
                process.StandardError,
                line => AppendOutputLine(line, standardError, progress),
                cancellationToken);

            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            await Task.WhenAll(standardOutputTask, standardErrorTask).ConfigureAwait(false);

            var combinedOutput = CombineOutput(standardOutput.ToString(), standardError.ToString());

            if (process.ExitCode != 0)
            {
                return new TranscribeFileResult(
                    false,
                    null,
                    options.ResultFilePath,
                    0,
                    0,
                    stopwatch.Elapsed,
                    [DesktopCliSupport.ExtractFailureMessage(combinedOutput)],
                    null);
            }

            if (!File.Exists(options.ResultFilePath))
            {
                throw new InvalidOperationException(
                    $"CLI transcription completed but no result file was created at {options.ResultFilePath}.");
            }

            progress?.Report(new ProgressUpdate(
                ProgressStage.Writing,
                90,
                stopwatch.Elapsed,
                "Reading CLI transcription output..."));

            var transcript = await _transcriptReader
                .ReadAsync(options.ResultFilePath, maxCharacters: 4000, cancellationToken)
                .ConfigureAwait(false);
            var metadata = DesktopCliSupport.ExtractSuccessMetadata(combinedOutput);

            progress?.Report(new ProgressUpdate(
                ProgressStage.Complete,
                100,
                stopwatch.Elapsed,
                "Complete"));

            return new TranscribeFileResult(
                true,
                metadata.DetectedLanguage,
                options.ResultFilePath,
                metadata.AcceptedSegmentCount,
                0,
                stopwatch.Elapsed,
                Array.Empty<string>(),
                transcript.Content);
        }
        finally
        {
            TryDelete(configurationPath);
        }
    }

    private static ProcessStartInfo CreateProcessStartInfo(string configurationPath)
    {
        var invocation = DesktopCliSupport.ResolveCliInvocation(AppContext.BaseDirectory);

        var startInfo = new ProcessStartInfo
        {
            FileName = "dotnet",
            WorkingDirectory = invocation.WorkingDirectory,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        if (!string.IsNullOrWhiteSpace(invocation.AssemblyPath))
        {
            // Prefer a bundled or prebuilt CLI assembly to avoid paying a `dotnet run` rebuild on every transcription.
            startInfo.ArgumentList.Add("exec");
            startInfo.ArgumentList.Add(invocation.AssemblyPath);
        }
        else if (!string.IsNullOrWhiteSpace(invocation.ProjectPath))
        {
            startInfo.ArgumentList.Add("run");
            startInfo.ArgumentList.Add("--project");
            startInfo.ArgumentList.Add(invocation.ProjectPath);
            startInfo.ArgumentList.Add("-c");
            startInfo.ArgumentList.Add("Debug");
        }
        else
        {
            throw new InvalidOperationException(
                "Could not locate the VoxFlow CLI bridge. Rebuild the Desktop app so the CLI output is available.");
        }

        startInfo.Environment["TRANSCRIPTION_SETTINGS_PATH"] = configurationPath;
        startInfo.Environment["VOXFLOW_PROGRESS_STREAM"] = "1";
        return startInfo;
    }

    private static string CombineOutput(string standardOutput, string standardError)
    {
        var builder = new StringBuilder();
        if (!string.IsNullOrWhiteSpace(standardOutput))
        {
            builder.AppendLine(standardOutput.Trim());
        }

        if (!string.IsNullOrWhiteSpace(standardError))
        {
            builder.AppendLine(standardError.Trim());
        }

        return builder.ToString().Trim();
    }

    private static async Task PumpReaderAsync(
        StreamReader reader,
        Action<string> handleLine,
        CancellationToken cancellationToken)
    {
        while (true)
        {
            var line = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
            if (line is null)
            {
                return;
            }

            handleLine(line);
        }
    }

    private static void AppendOutputLine(
        string line,
        StringBuilder builder,
        IProgress<ProgressUpdate>? progress)
    {
        if (DesktopCliSupport.TryParseProgressUpdate(line, out var progressUpdate))
        {
            progress?.Report(progressUpdate);
            return;
        }

        builder.AppendLine(line);
    }

    private static void TryKill(Process process)
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
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
        }
    }
}
