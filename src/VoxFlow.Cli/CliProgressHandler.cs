namespace VoxFlow.Cli;

using VoxFlow.Core.Models;

/// <summary>
/// Renders transcription progress updates to the console using inline rewriting.
/// </summary>
internal sealed class CliProgressHandler : IProgress<ProgressUpdate>
{
    public void Report(ProgressUpdate value)
    {
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
