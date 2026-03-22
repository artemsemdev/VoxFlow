using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

/// <summary>
/// Handles audio input validation and ffmpeg-based WAV conversion.
/// </summary>
internal static class AudioConversionService
{
    /// <summary>
    /// Verifies that the configured input file exists before processing begins.
    /// </summary>
    public static void ValidateInputFile(string inputFilePath)
    {
        if (!File.Exists(inputFilePath))
        {
            Console.WriteLine($"Input file not found: {inputFilePath}");
            throw new FileNotFoundException("Input audio file was not found.", inputFilePath);
        }

        Console.WriteLine($"Input file found: {inputFilePath}");
    }

    /// <summary>
    /// Verifies that ffmpeg can be executed from the configured path.
    /// </summary>
    public static async Task ValidateFfmpegAvailabilityAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken = default)
    {
        Console.WriteLine("Checking ffmpeg availability...");
        _ = await GetFfmpegVersionAsync(options, cancellationToken).ConfigureAwait(false);
        Console.WriteLine("ffmpeg is available.");
    }

    /// <summary>
    /// Returns the first version line reported by ffmpeg.
    /// </summary>
    public static async Task<string> GetFfmpegVersionAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken = default)
    {
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            var startInfo = CreateFfmpegStartInfo(options.FfmpegExecutablePath);
            startInfo.ArgumentList.Add("-version");

            var result = await RunProcessAsync(startInfo, cancellationToken).ConfigureAwait(false);

            if (result.ExitCode != 0)
            {
                throw new InvalidOperationException(
                    $"ffmpeg is unavailable. Exit code: {result.ExitCode}. {result.StandardError}".Trim());
            }

            var firstLine = result.StandardOutput
                .Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
                .FirstOrDefault();

            return string.IsNullOrWhiteSpace(firstLine) ? "ffmpeg is available." : firstLine;
        }
        catch (Win32Exception ex)
        {
            throw new InvalidOperationException("ffmpeg is not installed or not available in PATH.", ex);
        }
    }

    /// <summary>
    /// Converts the configured input file into the configured WAV format.
    /// </summary>
    public static async Task ConvertToWavAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Console.WriteLine($"WAV conversion started: {options.InputFilePath} -> {options.WavFilePath}");
        if (options.AudioFilterChain.Count > 0)
        {
            Console.WriteLine($"Applying ffmpeg audio filters: {string.Join(" | ", options.AudioFilterChain)}");
        }

        // Build the ffmpeg command explicitly so configuration values map
        // one-to-one to the final process arguments.
        var startInfo = CreateFfmpegStartInfo(options.FfmpegExecutablePath);

        if (options.OverwriteWavOutput)
        {
            startInfo.ArgumentList.Add("-y");
        }

        startInfo.ArgumentList.Add("-i");
        startInfo.ArgumentList.Add(options.InputFilePath);

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
        startInfo.ArgumentList.Add(options.WavFilePath);

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
            Console.WriteLine("WAV conversion failed.");
            throw new InvalidOperationException(
                $"ffmpeg conversion failed with exit code {result.ExitCode}: {result.StandardError}".Trim());
        }

        var outputInfo = new FileInfo(options.WavFilePath);
        if (!outputInfo.Exists || outputInfo.Length == 0)
        {
            Console.WriteLine("WAV conversion failed.");
            throw new InvalidOperationException("ffmpeg reported success, but the WAV file is missing or empty.");
        }

        Console.WriteLine("WAV conversion succeeded.");
    }

    /// <summary>
    /// Converts a specific input file into WAV format at the specified output path.
    /// Used by batch mode where input and output paths vary per file.
    /// </summary>
    public static async Task ConvertToWavAsync(
        string inputFilePath,
        string wavFilePath,
        TranscriptionOptions options,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Console.WriteLine($"WAV conversion started: {inputFilePath} -> {wavFilePath}");
        if (options.AudioFilterChain.Count > 0)
        {
            Console.WriteLine($"Applying ffmpeg audio filters: {string.Join(" | ", options.AudioFilterChain)}");
        }

        var startInfo = CreateFfmpegStartInfo(options.FfmpegExecutablePath);

        startInfo.ArgumentList.Add("-y");
        startInfo.ArgumentList.Add("-i");
        startInfo.ArgumentList.Add(inputFilePath);

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
        startInfo.ArgumentList.Add(wavFilePath);

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

        var outputInfo = new FileInfo(wavFilePath);
        if (!outputInfo.Exists || outputInfo.Length == 0)
        {
            throw new InvalidOperationException("ffmpeg reported success, but the WAV file is missing or empty.");
        }

        Console.WriteLine("WAV conversion succeeded.");
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
