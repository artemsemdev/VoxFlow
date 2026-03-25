using Microsoft.Extensions.DependencyInjection;
using VoxFlow.Core.DependencyInjection;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Models;

namespace VoxFlow.Cli;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        var services = new ServiceCollection();
        services.AddVoxFlowCore();
        // Fail fast on registration mistakes because this host is the composition root for the CLI pipeline.
        using var provider = services.BuildServiceProvider(new ServiceProviderOptions
        {
            ValidateOnBuild = true,
            ValidateScopes = true
        });

        using var cts = new CancellationTokenSource();

        // Convert Ctrl+C into cooperative cancellation so ffmpeg/model work can stop cleanly.
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            cts.Cancel();
            Console.Error.WriteLine("Cancellation requested. Stopping...");
        };

        try
        {
            var configService = provider.GetRequiredService<IConfigurationService>();
            var options = await configService.LoadAsync();

            // Run startup validation once at the host boundary so users get a complete preflight report
            // before any conversion or model-loading work begins.
            if (options.StartupValidation.Enabled)
            {
                var validationService = provider.GetRequiredService<IValidationService>();
                var validation = await validationService.ValidateAsync(options, cts.Token);
                ConsoleValidationReporter.Write(validation, options.StartupValidation.PrintDetailedReport);

                if (!validation.CanStart)
                {
                    Console.Error.WriteLine("Startup validation failed. Transcription will not start.");
                    return 1;
                }
            }
            else
            {
                Console.WriteLine("Startup validation is disabled by configuration.");
            }

            // Keep mode selection in the entry point so the Core services stay focused on one workflow each.
            if (options.IsBatchMode)
            {
                return await RunBatchAsync(provider, options, cts.Token);
            }

            return await RunSingleFileAsync(provider, options, cts.Token);
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine("Processing canceled.");
            return 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Processing failed: {ex.Message}");
            return 1;
        }
    }

    private static async Task<int> RunSingleFileAsync(
        ServiceProvider provider,
        VoxFlow.Core.Configuration.TranscriptionOptions options,
        CancellationToken cancellationToken)
    {
        Console.WriteLine("Starting transcription...");

        var transcriptionService = provider.GetRequiredService<ITranscriptionService>();
        var progress = new CliProgressHandler();
        // The CLI host resolves its input path from configuration rather than command-line arguments.
        var request = new TranscribeFileRequest(options.InputFilePath);
        var result = await transcriptionService.TranscribeFileAsync(request, progress, cancellationToken);

        if (!result.Success)
        {
            Console.Error.WriteLine("Transcription failed.");
            return 1;
        }

        Console.WriteLine($"Done. Language: {result.DetectedLanguage}, Segments: {result.AcceptedSegmentCount}");
        return 0;
    }

    private static async Task<int> RunBatchAsync(
        ServiceProvider provider,
        VoxFlow.Core.Configuration.TranscriptionOptions options,
        CancellationToken cancellationToken)
    {
        Console.WriteLine("Starting batch processing...");

        var batchService = provider.GetRequiredService<IBatchTranscriptionService>();
        var progress = new CliProgressHandler();
        var request = new BatchTranscribeRequest(
            options.Batch.InputDirectory,
            options.Batch.OutputDirectory,
            options.Batch.FilePattern,
            options.Batch.SummaryFilePath,
            options.Batch.StopOnFirstError,
            options.Batch.KeepIntermediateFiles);
        var result = await batchService.TranscribeBatchAsync(request, progress, cancellationToken);

        Console.WriteLine($"Batch complete: {result.Succeeded} succeeded, {result.Failed} failed, {result.Skipped} skipped.");

        if (!string.IsNullOrEmpty(result.SummaryFilePath))
        {
            Console.WriteLine($"Summary written to: {result.SummaryFilePath}");
        }

        // Preserve a conventional non-zero exit code when any file in the batch fails.
        return result.Failed > 0 ? 1 : 0;
    }
}
