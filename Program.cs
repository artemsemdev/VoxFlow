#nullable enable
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Whisper.net;

/// <summary>
/// Orchestrates application startup, validation, transcription, and output writing.
/// </summary>
internal static class Program
{
    /// <summary>
    /// Runs the transcription workflow and returns a process exit code.
    /// </summary>
    public static async Task<int> Main(string[] args)
    {
        using var cancellationTokenSource = new CancellationTokenSource();

        ConsoleCancelEventHandler? cancelHandler = null;
        cancelHandler = (_, eventArgs) =>
        {
            // Keep the process alive long enough for the current async operation
            // to observe the token and exit through the normal cancellation path.
            eventArgs.Cancel = true;
            cancellationTokenSource.Cancel();
            Console.Error.WriteLine("Cancellation requested. Stopping...");
        };

        Console.CancelKeyPress += cancelHandler;

        try
        {
            var options = TranscriptionOptions.Load();

            if (options.IsBatchMode)
            {
                return await RunBatchAsync(options, cancellationTokenSource.Token).ConfigureAwait(false);
            }

            return await RunSingleFileAsync(options, cancellationTokenSource.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine("Processing canceled.");
            return 1;
        }
        catch (UnsupportedLanguageException ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Processing failed: {ex.Message}");
            return 1;
        }
        finally
        {
            Console.CancelKeyPress -= cancelHandler;
        }
    }

    /// <summary>
    /// Runs the existing single-file transcription pipeline.
    /// </summary>
    private static async Task<int> RunSingleFileAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken)
    {
        if (options.StartupValidation.Enabled)
        {
            // Fail fast before conversion, model download, or transcription begin.
            var validationReport = await StartupValidationService.ValidateAsync(options, cancellationToken)
                .ConfigureAwait(false);
            StartupValidationConsoleReporter.Write(validationReport, options.StartupValidation.PrintDetailedReport);

            if (!validationReport.CanStart)
            {
                Console.Error.WriteLine("Startup validation failed. Transcription will not start.");
                return 1;
            }
        }
        else
        {
            Console.WriteLine("Startup validation is disabled by configuration.");
            AudioConversionService.ValidateInputFile(options.InputFilePath);
            await AudioConversionService.ValidateFfmpegAvailabilityAsync(options, cancellationToken)
                .ConfigureAwait(false);
        }

        Console.WriteLine("Starting transcription...");
        await AudioConversionService.ConvertToWavAsync(options, cancellationToken).ConfigureAwait(false);

        // Native Whisper teardown has shown instability on macOS after multi-language passes,
        // so the process intentionally keeps the factory alive until process exit.
        var whisperFactory = await ModelService.CreateFactoryAsync(options, cancellationToken)
            .ConfigureAwait(false);

        // Load the prepared WAV only after conversion and model setup succeed.
        var audioSamples = await WavAudioLoader.LoadSamplesAsync(
                options.WavFilePath,
                options,
                cancellationToken)
            .ConfigureAwait(false);
        var selectionResult = await LanguageSelectionService.SelectBestCandidateAsync(
            whisperFactory,
            audioSamples,
            options,
            cancellationToken).ConfigureAwait(false);

        Console.WriteLine($"Detected language: {selectionResult.Language.DisplayName} ({selectionResult.Language.Code})");

        await OutputWriter.WriteAsync(
                options.ResultFilePath,
                selectionResult.AcceptedSegments,
                cancellationToken)
            .ConfigureAwait(false);

        Console.WriteLine($"Final output file path: {options.ResultFilePath}");
        return 0;
    }

    /// <summary>
    /// Runs the batch processing pipeline for multiple input files.
    /// </summary>
    private static async Task<int> RunBatchAsync(
        TranscriptionOptions options,
        CancellationToken cancellationToken)
    {
        var batchOptions = options.Batch;

        if (options.StartupValidation.Enabled)
        {
            var validationReport = await StartupValidationService.ValidateAsync(options, cancellationToken)
                .ConfigureAwait(false);
            StartupValidationConsoleReporter.Write(validationReport, options.StartupValidation.PrintDetailedReport);

            if (!validationReport.CanStart)
            {
                Console.Error.WriteLine("Startup validation failed. Batch processing will not start.");
                return 1;
            }
        }

        Console.WriteLine("Starting batch processing...");

        // Create the Whisper factory once and reuse it across all files (ADR-010, ADR-011).
        var whisperFactory = await ModelService.CreateFactoryAsync(options, cancellationToken)
            .ConfigureAwait(false);

        var discoveredFiles = FileDiscoveryService.DiscoverInputFiles(batchOptions);
        Console.WriteLine($"Discovered {discoveredFiles.Count} file(s) in: {batchOptions.InputDirectory}");

        var results = new List<FileProcessingResult>(discoveredFiles.Count);

        for (var i = 0; i < discoveredFiles.Count; i++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var file = discoveredFiles[i];

            if (file.Status == DiscoveryStatus.Skipped)
            {
                Console.WriteLine($"[{i + 1}/{discoveredFiles.Count}] Skipping: {Path.GetFileName(file.InputPath)} -- {file.SkipReason}");
                results.Add(new FileProcessingResult(
                    file.InputPath, file.OutputPath, FileProcessingStatus.Skipped,
                    file.SkipReason, TimeSpan.Zero, null));
                continue;
            }

            Console.WriteLine($"[{i + 1}/{discoveredFiles.Count}] Processing: {Path.GetFileName(file.InputPath)}");
            var stopwatch = Stopwatch.StartNew();

            try
            {
                var result = await ProcessSingleFileAsync(
                    file.InputPath, file.TempWavPath, file.OutputPath,
                    whisperFactory, options, cancellationToken).ConfigureAwait(false);
                stopwatch.Stop();

                results.Add(new FileProcessingResult(
                    file.InputPath, file.OutputPath, FileProcessingStatus.Success,
                    null, stopwatch.Elapsed, result));

                Console.WriteLine($"[{i + 1}/{discoveredFiles.Count}] Completed: {Path.GetFileName(file.InputPath)} ({result}, {stopwatch.Elapsed:hh\\:mm\\:ss})");
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                stopwatch.Stop();
                Console.Error.WriteLine($"[{i + 1}/{discoveredFiles.Count}] Failed: {Path.GetFileName(file.InputPath)} -- {ex.Message}");

                results.Add(new FileProcessingResult(
                    file.InputPath, file.OutputPath, FileProcessingStatus.Failed,
                    ex.Message, stopwatch.Elapsed, null));

                if (batchOptions.StopOnFirstError)
                {
                    Console.Error.WriteLine("Stopping batch: stopOnFirstError is enabled.");
                    break;
                }
            }
            finally
            {
                CleanupTempWav(file.TempWavPath, batchOptions.KeepIntermediateFiles);
            }
        }

        await BatchSummaryWriter.WriteAsync(batchOptions.SummaryFilePath, results, cancellationToken)
            .ConfigureAwait(false);

        var succeeded = results.Count(r => r.Status == FileProcessingStatus.Success);
        var failed = results.Count(r => r.Status == FileProcessingStatus.Failed);
        var skipped = results.Count(r => r.Status == FileProcessingStatus.Skipped);

        Console.WriteLine($"Batch complete: {succeeded} succeeded, {failed} failed, {skipped} skipped.");
        Console.WriteLine($"Summary written to: {batchOptions.SummaryFilePath}");

        return failed > 0 ? 1 : 0;
    }

    /// <summary>
    /// Processes a single file through the transcription pipeline.
    /// Returns the detected language display name on success.
    /// </summary>
    private static async Task<string> ProcessSingleFileAsync(
        string inputPath,
        string wavPath,
        string outputPath,
        WhisperFactory whisperFactory,
        TranscriptionOptions options,
        CancellationToken cancellationToken)
    {
        await AudioConversionService.ConvertToWavAsync(inputPath, wavPath, options, cancellationToken)
            .ConfigureAwait(false);

        var audioSamples = await WavAudioLoader.LoadSamplesAsync(wavPath, options, cancellationToken)
            .ConfigureAwait(false);

        var selectionResult = await LanguageSelectionService.SelectBestCandidateAsync(
            whisperFactory, audioSamples, options, cancellationToken).ConfigureAwait(false);

        await OutputWriter.WriteAsync(outputPath, selectionResult.AcceptedSegments, cancellationToken)
            .ConfigureAwait(false);

        return $"{selectionResult.Language.DisplayName} ({selectionResult.Language.Code})";
    }

    /// <summary>
    /// Removes the intermediate WAV file unless retention is configured.
    /// </summary>
    private static void CleanupTempWav(string wavPath, bool keepIntermediateFiles)
    {
        if (keepIntermediateFiles)
        {
            return;
        }

        try
        {
            if (File.Exists(wavPath))
            {
                File.Delete(wavPath);
            }
        }
        catch
        {
            // Best-effort cleanup for temp files.
        }
    }
}
