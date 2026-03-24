using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using VoxFlow.Core.Configuration;
using VoxFlow.Core.Interfaces;

namespace VoxFlow.Core.Services;

/// <summary>
/// Handles audio format conversion using ffmpeg.
/// </summary>
internal sealed class AudioConversionService : IAudioConversionService
{
    /// <summary>
    /// Converts a specific input file into WAV format at the specified output path.
    /// </summary>
    public async Task ConvertToWavAsync(
        string inputPath,
        string outputPath,
        TranscriptionOptions options,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();

        var startInfo = CreateFfmpegStartInfo(options.FfmpegExecutablePath);

        startInfo.ArgumentList.Add("-y");
        startInfo.ArgumentList.Add("-i");
        startInfo.ArgumentList.Add(inputPath);

        if (options.AudioFilterChain.Count > 0)
        {
            startInfo.ArgumentList.Add("-af");
            startInfo.ArgumentList.Add(string.Join(",", options.AudioFilterChain));
        }

        startInfo.ArgumentList.Add("-ar");
        startInfo.ArgumentList.Add(options.OutputSampleRate.ToString(CultureInfo.InvariantCulture));
        startInfo.ArgumentList.Add("-ac");
        startInfo.ArgumentList.Add(options.OutputChannelCount.ToString(CultureInfo.InvariantCulture));
        startInfo.ArgumentList.Add("-f");
        startInfo.ArgumentList.Add(options.OutputContainerFormat);
        startInfo.ArgumentList.Add(outputPath);

        ProcessRunResult result;
        try
        {
            result = await RunProcessAsync(startInfo, cancellationToken).ConfigureAwait(false);
        }
        catch (Win32Exception ex)
        {
            throw new InvalidOperationException("Failed to start ffmpeg for WAV conversion.", ex);
        }

        if (result.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"ffmpeg conversion failed with exit code {result.ExitCode}: {result.StandardError}".Trim());
        }

        var outputInfo = new FileInfo(outputPath);
        if (!outputInfo.Exists || outputInfo.Length == 0)
        {
            throw new InvalidOperationException("ffmpeg reported success, but the WAV file is missing or empty.");
        }
    }

    /// <summary>
    /// Verifies that ffmpeg can be executed from the configured path.
    /// </summary>
    public async Task<bool> ValidateFfmpegAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken = default)
    {
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            var startInfo = CreateFfmpegStartInfo(options.FfmpegExecutablePath);
            startInfo.ArgumentList.Add("-version");

            var result = await RunProcessAsync(startInfo, cancellationToken).ConfigureAwait(false);
            return result.ExitCode == 0;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Creates a common ffmpeg process start configuration.
    /// </summary>
    private static ProcessStartInfo CreateFfmpegStartInfo(string ffmpegPath)
    {
        return new ProcessStartInfo
        {
            FileName = ffmpegPath,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
    }

    /// <summary>
    /// Runs a process, captures its output streams, and returns the combined result.
    /// </summary>
    private static async Task<ProcessRunResult> RunProcessAsync(
        ProcessStartInfo startInfo,
        CancellationToken cancellationToken)
    {
        using var process = new Process { StartInfo = startInfo };
        process.Start();

        using var cancellationRegistration = cancellationToken.Register(() =>
        {
            try
            {
                if (!process.HasExited)
                {
                    // External tools do not understand .NET cancellation tokens,
                    // so cancellation is enforced by terminating the child process.
                    process.Kill(entireProcessTree: true);
                }
            }
            catch (InvalidOperationException)
            {
            }
        });

        var standardErrorTask = process.StandardError.ReadToEndAsync(cancellationToken);
        var standardOutputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);

        // Wait for process completion first, then await both stream reads so the
        // caller always gets the complete captured output for diagnostics.
        await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);

        var standardError = await standardErrorTask.ConfigureAwait(false);
        var standardOutput = await standardOutputTask.ConfigureAwait(false);

        return new ProcessRunResult(process.ExitCode, standardOutput, standardError);
    }

    private sealed record ProcessRunResult(int ExitCode, string StandardOutput, string StandardError);
}
