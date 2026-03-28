namespace VoxFlow.Cli;

using System.Text.Json;
using VoxFlow.Core.Models;

/// <summary>
/// Renders transcription progress updates to the console using inline rewriting.
/// </summary>
internal sealed class CliProgressHandler : IProgress<ProgressUpdate>
{
    private const string StructuredProgressPrefix = "VOXFLOW_PROGRESS ";

    public void Report(ProgressUpdate value)
    {
        if (string.Equals(Environment.GetEnvironmentVariable("VOXFLOW_PROGRESS_STREAM"), "1", StringComparison.Ordinal))
        {
            var payload = JsonSerializer.Serialize(new CliProgressEnvelope(
                value.Stage.ToString(),
                value.PercentComplete,
                (long)value.Elapsed.TotalMilliseconds,
                value.Message,
                value.CurrentLanguage,
                value.BatchFileIndex,
                value.BatchFileTotal));

            Console.Error.WriteLine($"{StructuredProgressPrefix}{payload}");
            return;
        }

        var prefix = value.Stage switch
        {
            ProgressStage.Validating => "Validating",
            ProgressStage.Converting => "Converting",
            ProgressStage.LoadingModel => "Loading model",
            ProgressStage.Transcribing => "Transcribing",
            ProgressStage.Filtering => "Filtering",
            ProgressStage.Writing => "Writing",
            ProgressStage.Complete => "Complete",
            ProgressStage.Failed => "Failed",
            _ => "Working"
        };

        Console.Write($"\r[{value.PercentComplete:F0}%] {prefix}");
        if (value.Message != null) Console.Write($" - {value.Message}");
        Console.Write("          "); // Clear trailing chars

        if (value.Stage is ProgressStage.Complete or ProgressStage.Failed)
            Console.WriteLine();
    }
}

internal sealed record CliProgressEnvelope(
    string Stage,
    double PercentComplete,
    long ElapsedMilliseconds,
    string? Message,
    string? CurrentLanguage,
    int? BatchFileIndex,
    int? BatchFileTotal);
