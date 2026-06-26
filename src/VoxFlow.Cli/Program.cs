using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using VoxFlow.Core.DependencyInjection;
using VoxFlow.Core.Interfaces;
using VoxFlow.Core.Logging;
using VoxFlow.Core.Models;

namespace VoxFlow.Cli;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        // Route to a verb first. No args or a leading flag means the default verb
        // (transcribe), so `voxflow --speakers` keeps working unchanged.
        CliRoute route;
        try
        {
            route = CliRouter.Route(args);
        }
        catch (ArgumentException ex)
        {
            CliOutput.WriteErrorLine(ex.Message);
            return 2;
        }

        if (route.Verb is CliVerb.Setup)
        {
            // Recognized command whose behavior ships with the speaker-labeling
            // setup work; the dispatch surface exists so it can plug in later.
            CliOutput.WriteLine(
                "voxflow setup is not available yet — it ships with the speaker-labeling setup work.");
            return 2;
        }

        var services = new ServiceCollection();
        services.AddLogging(builder =>
            builder.AddProvider(new TextWriterLoggerProvider(CliOutput.Error)));
        services.AddVoxFlowCore();
        // Fail fast on registration mistakes because this host is the composition root for the CLI pipeline.
        using var provider = services.BuildServiceProvider(new ServiceProviderOptions
        {
            ValidateOnBuild = true,
            ValidateScopes = true
        });
        var logger = provider
            .GetRequiredService<ILoggerFactory>()
            .CreateLogger("VoxFlow.Cli");

        if (route.Verb is CliVerb.Doctor)
        {
            using var doctorCts = new CancellationTokenSource();
            Console.CancelKeyPress += (_, e) => { e.Cancel = true; doctorCts.Cancel(); };
            var doctor = provider.GetRequiredService<VoxFlow.Core.Services.Diarization.ISpeakerLabelingDoctor>();
            return await DoctorCommand.RunAsync(doctor, route.Args, doctorCts.Token);
        }

        CliArguments cliArgs;
        try
        {
            cliArgs = CliArguments.Parse(route.Args);
        }
        catch (ArgumentException ex)
        {
            logger.LogError("{Message}", ex.Message);
            // Distinct exit code so scripts can tell "user typed a bad flag" (2) apart
            // from "startup validation failed" (1).
            return 2;
        }

        if (cliArgs.ShowHelp)
        {
            CliOutput.WriteLine(CliArguments.HelpText);
            return 0;
        }

        using var cts = new CancellationTokenSource();

        // Convert Ctrl+C into cooperative cancellation so ffmpeg/model work can stop cleanly.
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            cts.Cancel();
            logger.LogWarning("Cancellation requested. Stopping...");
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
                    logger.LogError("Startup validation failed. Transcription will not start.");
                    return 1;
                }
            }
            else
            {
                logger.LogInformation("Startup validation is disabled by configuration.");
            }

            // Keep mode selection in the entry point so the Core services stay focused on one workflow each.
            if (options.IsBatchMode)
            {
                return await RunBatchAsync(provider, logger, options, cliArgs.EnableSpeakers, cts.Token);
            }

            return await RunSingleFileAsync(provider, logger, options, cliArgs.EnableSpeakers, cts.Token);
        }
        catch (OperationCanceledException)
        {
            logger.LogWarning("Processing canceled.");
            return 1;
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Processing failed: {Message}", ex.Message);
            return 1;
        }
    }

    private static async Task<int> RunSingleFileAsync(
        ServiceProvider provider,
        ILogger logger,
        VoxFlow.Core.Configuration.TranscriptionOptions options,
        bool? enableSpeakersOverride,
        CancellationToken cancellationToken)
    {
        logger.LogInformation("Starting transcription...");

        var transcriptionService = provider.GetRequiredService<ITranscriptionService>();
        using var progress = new CliProgressHandler(options.ConsoleProgress);
        // The CLI host resolves its input path from configuration rather than command-line arguments.
        var request = new TranscribeFileRequest(
            options.InputFilePath,
            EnableSpeakers: enableSpeakersOverride);
        var result = await transcriptionService.TranscribeFileAsync(request, progress, cancellationToken);

        if (!result.Success)
        {
            logger.LogError("Transcription failed.");
            return 1;
        }

        logger.LogInformation(
            "Done. Language: {DetectedLanguage}, Segments: {AcceptedSegmentCount}",
            result.DetectedLanguage,
            result.AcceptedSegmentCount);
        logger.LogInformation("Result written to: {ResultFilePath}", result.ResultFilePath);
        return 0;
    }

    private static async Task<int> RunBatchAsync(
        ServiceProvider provider,
        ILogger logger,
        VoxFlow.Core.Configuration.TranscriptionOptions options,
        bool? enableSpeakersOverride,
        CancellationToken cancellationToken)
    {
        logger.LogInformation("Starting batch processing...");

        var batchService = provider.GetRequiredService<IBatchTranscriptionService>();
        using var progress = new CliProgressHandler(options.ConsoleProgress);
        var request = new BatchTranscribeRequest(
            options.Batch.InputDirectory,
            options.Batch.OutputDirectory,
            options.Batch.FilePattern,
            options.Batch.SummaryFilePath,
            options.Batch.StopOnFirstError,
            options.Batch.KeepIntermediateFiles,
            EnableSpeakers: enableSpeakersOverride);
        var result = await batchService.TranscribeBatchAsync(request, progress, cancellationToken);

        logger.LogInformation(
            "Batch complete: {Succeeded} succeeded, {Failed} failed, {Skipped} skipped.",
            result.Succeeded,
            result.Failed,
            result.Skipped);

        if (!string.IsNullOrEmpty(result.SummaryFilePath))
        {
            logger.LogInformation("Summary written to: {SummaryFilePath}", result.SummaryFilePath);
        }

        // Preserve a conventional non-zero exit code when any file in the batch fails.
        return result.Failed > 0 ? 1 : 0;
    }
}
